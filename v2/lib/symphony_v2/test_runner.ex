defmodule SymphonyV2.TestRunner do
  @moduledoc """
  Runs the configured test command in a workspace and captures the result.

  Executes the test command via an Erlang Port with timeout support,
  captures stdout/stderr, and returns a structured TestResult.
  """

  require Logger

  alias SymphonyV2.Plans
  alias SymphonyV2.TestRunner.TestResult

  @default_timeout_ms 300_000

  @doc """
  Runs the test command in the given workspace directory.

  Returns a structured TestResult with pass/fail status, exit code,
  captured output, and duration.

  ## Options

    * `:timeout_ms` - Maximum time to wait for tests (default: 300_000ms / 5 min)

  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, TestResult.t()} | {:error, term()}
  def run(workspace, test_command, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if File.dir?(workspace) do
      execute(workspace, test_command, timeout_ms)
    else
      {:error, :workspace_not_found}
    end
  end

  @doc """
  Runs tests and persists the result to the subtask record.

  Writes test output to a log file in the workspace and updates
  the subtask's test_passed and test_output fields.
  """
  @spec run_and_persist(String.t(), String.t(), struct(), keyword()) ::
          {:ok, TestResult.t()} | {:error, term()}
  def run_and_persist(workspace, test_command, subtask, opts \\ []) do
    case run(workspace, test_command, opts) do
      {:ok, result} ->
        write_log_file(workspace, result)
        persist_to_subtask(subtask, result)
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  # --- Private ---

  defp execute(workspace, test_command, timeout_ms) do
    {shell, shell_flag} = shell_command()
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [shell_flag, test_command],
        cd: workspace,
        env: []
      ])

    timer_ref = Process.send_after(self(), {:test_timeout, port}, timeout_ms)

    result = collect_output(port, timer_ref, [], started_at)
    result
  end

  defp collect_output(port, timer_ref, output_acc, started_at) do
    receive do
      {^port, {:data, data}} ->
        text = IO.iodata_to_binary(data)
        collect_output(port, timer_ref, [text | output_acc], started_at)

      {^port, {:exit_status, exit_code}} ->
        cancel_timer(timer_ref, port)
        duration_ms = System.monotonic_time(:millisecond) - started_at
        output = output_acc |> Enum.reverse() |> IO.iodata_to_binary()

        {:ok,
         %TestResult{
           passed: exit_code == 0,
           exit_code: exit_code,
           output: output,
           duration_ms: duration_ms
         }}

      {:test_timeout, ^port} ->
        kill_port(port)
        duration_ms = System.monotonic_time(:millisecond) - started_at
        output = output_acc |> Enum.reverse() |> IO.iodata_to_binary()

        # Drain any remaining messages from the port
        drain_port_messages(port)

        {:ok,
         %TestResult{
           passed: false,
           exit_code: 137,
           output: output <> "\n[TEST TIMEOUT after #{duration_ms}ms]",
           duration_ms: duration_ms
         }}
    end
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp write_log_file(workspace, result) do
    log_dir = Path.join([workspace, ".symphony", "logs"])
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "test_output.log")
    File.write!(log_path, result.output)
  end

  defp persist_to_subtask(subtask, result) do
    # Truncate output to avoid exceeding text column limits
    truncated_output = truncate_output(result.output, 100_000)

    case Plans.update_subtask(subtask, %{
           test_passed: result.passed,
           test_output: truncated_output
         }) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to persist test result to subtask",
          subtask_id: subtask.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp truncate_output(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp truncate_output(output, max_bytes) do
    truncated = binary_part(output, byte_size(output) - max_bytes, max_bytes)
    "[...truncated...]\n" <> truncated
  end

  defp shell_command do
    case :os.type() do
      {:unix, _} -> {System.find_executable("sh"), "-c"}
      {:win32, _} -> {System.find_executable("cmd"), "/c"}
    end
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

  defp cancel_timer(timer_ref, port) do
    Process.cancel_timer(timer_ref)

    receive do
      {:test_timeout, ^port} -> :ok
    after
      0 -> :ok
    end
  end
end
