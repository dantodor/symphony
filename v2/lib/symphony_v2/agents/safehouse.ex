defmodule SymphonyV2.Agents.Safehouse do
  @moduledoc """
  Builds CLI commands for running agents inside Agent Safehouse.

  Agent Safehouse provides macOS kernel-level sandboxing via `sandbox-exec`.
  All agents run with a deny-first filesystem policy, with explicit grants
  for workspace directories.

  ## Command Structure

      safehouse [safehouse_flags] -- <agent_command> [agent_flags]

  Safehouse flags:
  - `--add-dirs=<path>` — writable directory access
  - `--add-dirs-ro=<path>` — read-only directory access
  - `--env-pass=<VAR1>,<VAR2>` — forward environment variables into sandbox

  Agent flags are built by the AgentRegistry based on agent type.
  """

  alias SymphonyV2.Agents.AgentRegistry

  @safehouse_command "safehouse"

  @doc """
  Builds the full safehouse-wrapped command for an agent invocation.

  Returns `{:ok, {command, args}}` where `command` is "safehouse" and `args`
  includes all safehouse flags, the separator `--`, and the agent command with
  its flags.

  ## Options

  - `:prompt` — the prompt string to pass to the agent (required)
  - `:read_only_dirs` — list of read-only directory paths (default: `[]`)
  - `:env_vars` — additional environment variable names to forward (default: `[]`)
  - `:skip_permissions` — whether to add the agent's skip-permissions flag (default: `true`)

  ## Examples

      iex> Safehouse.build_command(:claude_code, "/path/to/workspace", prompt: "Fix the bug")
      {:ok, {"safehouse",
        ["--add-dirs=/path/to/workspace",
         "--env-pass=ANTHROPIC_API_KEY",
         "--", "claude", "-p", "Fix the bug",
         "--dangerously-skip-permissions"]}}
  """
  @spec build_command(atom(), String.t(), keyword()) ::
          {:ok, {String.t(), [String.t()]}} | {:error, String.t()}
  def build_command(agent_type, workspace_path, opts \\ []) do
    with :ok <- maybe_validate_safehouse(opts),
         :ok <- validate_path(workspace_path),
         {:ok, agent} <- fetch_agent(agent_type) do
      prompt = Keyword.fetch!(opts, :prompt)
      read_only_dirs = Keyword.get(opts, :read_only_dirs, [])
      extra_env_vars = Keyword.get(opts, :env_vars, [])
      skip_permissions = Keyword.get(opts, :skip_permissions, true)

      with :ok <- validate_paths(read_only_dirs) do
        safehouse_args =
          build_safehouse_args(workspace_path, read_only_dirs, agent, extra_env_vars)

        agent_args = build_agent_args(agent, prompt, skip_permissions)

        {:ok, {@safehouse_command, safehouse_args ++ ["--"] ++ agent_args}}
      end
    end
  end

  @doc """
  Builds the command as a flat list suitable for `System.cmd/3` or Erlang ports.

  Returns `{:ok, [command | args]}` for convenience when the caller needs
  a single list.
  """
  @spec build_command_list(atom(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build_command_list(agent_type, workspace_path, opts \\ []) do
    with {:ok, {command, args}} <- build_command(agent_type, workspace_path, opts) do
      {:ok, [command | args]}
    end
  end

  @doc "Returns whether the safehouse binary is available in PATH."
  @spec safehouse_available?() :: boolean()
  def safehouse_available? do
    System.find_executable(@safehouse_command) != nil
  end

  defp maybe_validate_safehouse(opts) do
    if Keyword.get(opts, :skip_safehouse_check, false) do
      :ok
    else
      validate_safehouse_available()
    end
  end

  defp validate_safehouse_available do
    if safehouse_available?() do
      :ok
    else
      {:error, "#{@safehouse_command} binary not found in PATH"}
    end
  end

  defp fetch_agent(agent_type) do
    case AgentRegistry.get(agent_type) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, "unknown agent type: #{inspect(agent_type)}"}
    end
  end

  defp build_safehouse_args(workspace_path, read_only_dirs, agent, extra_env_vars) do
    writable_flag = ["--add-dirs=#{workspace_path}"]
    read_only_flags = Enum.map(read_only_dirs, &"--add-dirs-ro=#{&1}")
    env_flags = build_env_flags(agent, extra_env_vars)

    writable_flag ++ read_only_flags ++ env_flags
  end

  defp build_env_flags(agent, extra_env_vars) do
    all_vars = Enum.uniq(agent.env_vars ++ extra_env_vars)

    case all_vars do
      [] -> []
      vars -> ["--env-pass=#{Enum.join(vars, ",")}"]
    end
  end

  defp build_agent_args(agent, prompt, skip_permissions) do
    base = [agent.command, agent.prompt_flag, prompt]

    permissions_flag =
      if skip_permissions && agent.skip_permissions_flag do
        [agent.skip_permissions_flag]
      else
        []
      end

    base ++ permissions_flag
  end

  defp validate_path(path) when is_binary(path) do
    if safe_path?(path) do
      :ok
    else
      {:error, "unsafe path: #{inspect(path)}"}
    end
  end

  defp validate_path(path), do: {:error, "invalid path type: #{inspect(path)}"}

  defp validate_paths(paths) do
    case Enum.find(paths, fn path -> !safe_path?(path) end) do
      nil -> :ok
      bad_path -> {:error, "unsafe path: #{inspect(bad_path)}"}
    end
  end

  # Reject paths that could be used for shell injection or command manipulation.
  # Paths must be non-empty strings without shell metacharacters.
  defp safe_path?(path) when is_binary(path) do
    path != "" and
      not String.contains?(path, [
        "\0",
        ";",
        "|",
        "&",
        "`",
        "$(",
        "$()",
        "\n",
        "\r"
      ])
  end

  defp safe_path?(_), do: false
end
