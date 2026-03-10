defmodule SymphonyV2.Agents.AgentProcess do
  @moduledoc """
  GenServer that manages a single agent CLI process.

  Spawns the agent command via an Erlang Port, streams stdout/stderr,
  broadcasts output via PubSub, and persists results to the AgentRun record
  on completion.
  """
  use GenServer, restart: :temporary

  require Logger

  alias SymphonyV2.Agents.Safehouse
  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics

  @type start_opts :: %{
          agent_type: atom(),
          workspace: String.t(),
          agent_run_id: Ecto.UUID.t(),
          prompt: String.t(),
          caller: pid(),
          timeout_ms: pos_integer(),
          safehouse_opts: keyword()
        }

  @type result :: %{
          agent_run_id: Ecto.UUID.t(),
          exit_code: integer(),
          status: :succeeded | :failed | :timeout,
          duration_ms: integer(),
          stdout_log_path: String.t()
        }

  # --- Public API ---

  @doc "Starts an AgentProcess under the AgentSupervisor."
  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    agent_type = Map.fetch!(opts, :agent_type)
    workspace = Map.fetch!(opts, :workspace)
    agent_run_id = Map.fetch!(opts, :agent_run_id)
    prompt = Map.fetch!(opts, :prompt)
    caller = Map.fetch!(opts, :caller)
    timeout_ms = Map.get(opts, :timeout_ms, 600_000)
    safehouse_opts = Map.get(opts, :safehouse_opts, [])

    command_result = resolve_command(agent_type, workspace, prompt, safehouse_opts)

    case command_result do
      {:ok, {command, args}} ->
        log_path = build_log_path(workspace, agent_run_id)
        ensure_log_dir(log_path)

        started_at = System.monotonic_time(:millisecond)

        port = open_port(command, args, workspace)
        timer_ref = Process.send_after(self(), :timeout, timeout_ms)

        state = %{
          port: port,
          agent_run_id: agent_run_id,
          caller: caller,
          started_at: started_at,
          timeout_ms: timeout_ms,
          timer_ref: timer_ref,
          output: [],
          log_path: log_path,
          log_file: File.open!(log_path, [:write, :utf8]),
          exit_code: nil,
          timed_out: false
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:command_build_error, reason}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    text = IO.iodata_to_binary(data)

    # Write to log file
    IO.write(state.log_file, text)

    # Broadcast via PubSub
    Phoenix.PubSub.broadcast(
      SymphonyV2.PubSub,
      Topics.agent_output(state.agent_run_id),
      {:agent_output, state.agent_run_id, text}
    )

    {:noreply, %{state | output: [text | state.output]}}
  end

  def handle_info({port, {:exit_status, _exit_code}}, %{port: port, timed_out: true} = state) do
    # Already handled via timeout — ignore late exit_status
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    cancel_timer(state.timer_ref)
    finish(state, exit_code)
  end

  def handle_info(:timeout, state) do
    Logger.warning("Agent process timed out",
      agent_run_id: state.agent_run_id,
      timeout_ms: state.timeout_ms
    )

    kill_port(state.port)
    finish(%{state | timed_out: true}, 137)
  end

  # Handle port closed (can happen if process exits before we get exit_status on some platforms)
  def handle_info({port, :closed}, %{port: port} = state) do
    cancel_timer(state.timer_ref)
    # If we haven't received exit_status yet, treat as failure
    if state.exit_code == nil do
      finish(state, 1)
    else
      {:noreply, state}
    end
  end

  # Handle DOWN from port
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    cancel_timer(state.timer_ref)

    if state.exit_code == nil do
      finish(state, 1)
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_log_file(state)
    kill_port_if_open(state)
    :ok
  end

  # --- Private ---

  defp resolve_command(agent_type, workspace, prompt, safehouse_opts) do
    case Keyword.get(safehouse_opts, :command_override) do
      {command, args} ->
        {:ok, {command, args}}

      nil ->
        all_opts = Keyword.put(safehouse_opts, :prompt, prompt)
        Safehouse.build_command(agent_type, workspace, all_opts)
    end
  end

  defp open_port(command, args, workspace) do
    command_path = System.find_executable(command) || command

    Port.open({:spawn_executable, command_path}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      cd: workspace,
      env: []
    ])
  end

  defp finish(state, exit_code) do
    close_log_file(state)

    duration_ms = System.monotonic_time(:millisecond) - state.started_at

    status =
      cond do
        state.timed_out -> :timeout
        exit_code == 0 -> :succeeded
        true -> :failed
      end

    # Persist to database
    persist_result(state.agent_run_id, %{
      status: Atom.to_string(status),
      exit_code: exit_code,
      duration_ms: duration_ms,
      stdout_log_path: state.log_path,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    result = %{
      agent_run_id: state.agent_run_id,
      exit_code: exit_code,
      status: status,
      duration_ms: duration_ms,
      stdout_log_path: state.log_path
    }

    # Notify caller
    send(state.caller, {:agent_complete, result})

    # Broadcast completion via PubSub
    Phoenix.PubSub.broadcast(
      SymphonyV2.PubSub,
      Topics.agent_output(state.agent_run_id),
      {:agent_complete, state.agent_run_id, result}
    )

    {:stop, :normal, %{state | exit_code: exit_code}}
  end

  defp persist_result(agent_run_id, attrs) do
    case SymphonyV2.Repo.get(SymphonyV2.Plans.AgentRun, agent_run_id) do
      nil ->
        Logger.error("AgentRun not found for persistence",
          agent_run_id: agent_run_id
        )

      agent_run ->
        case Plans.complete_agent_run(agent_run, attrs) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.error("Failed to persist agent run result",
              agent_run_id: agent_run_id,
              errors: inspect(changeset.errors)
            )
        end
    end
  end

  defp build_log_path(workspace, agent_run_id) do
    Path.join([workspace, ".symphony", "logs", "#{agent_run_id}.log"])
  end

  defp ensure_log_dir(log_path) do
    log_path |> Path.dirname() |> File.mkdir_p!()
  end

  defp close_log_file(%{log_file: nil}), do: :ok
  defp close_log_file(%{log_file: file}), do: File.close(file)

  defp kill_port_if_open(%{port: port}) do
    if Port.info(port) != nil do
      kill_port(port)
    end
  rescue
    # Port may already be closed
    ArgumentError -> :ok
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", "#{os_pid}"])

      nil ->
        :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    # Flush any timeout message that may have arrived
    receive do
      :timeout -> :ok
    after
      0 -> :ok
    end
  end
end
