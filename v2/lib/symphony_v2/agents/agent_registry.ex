defmodule SymphonyV2.Agents.AgentRegistry do
  @moduledoc """
  Registry of available coding agents and their CLI configurations.

  Provides built-in definitions for supported agents (Claude Code, Codex,
  Gemini CLI, Opencode) and supports extending with custom agents via
  application configuration.

  ## Configuration

  Custom agents can be added via application config:

      config :symphony_v2, SymphonyV2.Agents.AgentRegistry,
        custom_agents: [
          %{
            name: :custom_agent,
            command: "custom-cli",
            prompt_flag: "--prompt",
            skip_permissions_flag: "--no-confirm",
            env_vars: ["CUSTOM_API_KEY"]
          }
        ]
  """

  alias SymphonyV2.Agents.AgentDef

  @builtin_agents [
    %AgentDef{
      name: :claude_code,
      command: "claude",
      skip_permissions_flag: "--dangerously-skip-permissions",
      prompt_flag: "-p",
      env_vars: ["ANTHROPIC_API_KEY"]
    },
    %AgentDef{
      name: :codex,
      command: "codex",
      skip_permissions_flag: "--dangerously-bypass-approvals-and-sandbox",
      prompt_flag: "-q",
      env_vars: ["OPENAI_API_KEY"]
    },
    %AgentDef{
      name: :gemini_cli,
      command: "gemini",
      skip_permissions_flag: nil,
      prompt_flag: "-p",
      env_vars: ["GEMINI_API_KEY"]
    },
    %AgentDef{
      name: :opencode,
      command: "opencode",
      skip_permissions_flag: nil,
      prompt_flag: "-p",
      env_vars: []
    }
  ]

  @doc "Returns all registered agents (built-in + custom)."
  @spec all() :: [AgentDef.t()]
  def all do
    @builtin_agents ++ custom_agents()
  end

  @doc "Returns the AgentDef for the given agent type (atom or string)."
  @spec get(atom() | String.t()) :: {:ok, AgentDef.t()} | {:error, :not_found}
  def get(agent_type) when is_atom(agent_type) do
    case Enum.find(all(), fn agent -> agent.name == agent_type end) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  def get(agent_type) when is_binary(agent_type) do
    get(String.to_existing_atom(agent_type))
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc "Returns all registered agent type names as atoms."
  @spec agent_names() :: [atom()]
  def agent_names do
    Enum.map(all(), & &1.name)
  end

  @doc "Returns all registered agent type names as strings."
  @spec agent_type_strings() :: [String.t()]
  def agent_type_strings do
    Enum.map(all(), &Atom.to_string(&1.name))
  end

  @doc "Checks whether the given agent type is registered."
  @spec registered?(atom() | String.t()) :: boolean()
  def registered?(agent_type) do
    case get(agent_type) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Builds the CLI command list for an agent invocation.

  Returns `{command, args}` where `command` is the executable and `args`
  is a list of arguments including the prompt and optional skip-permissions flag.
  """
  @spec build_command(atom(), String.t(), keyword()) ::
          {:ok, {String.t(), [String.t()]}} | {:error, :not_found}
  def build_command(agent_type, prompt, opts \\ []) do
    with {:ok, agent} <- get(agent_type) do
      skip_permissions = Keyword.get(opts, :skip_permissions, false)

      args =
        [agent.prompt_flag, prompt] ++
          if(skip_permissions && agent.skip_permissions_flag,
            do: [agent.skip_permissions_flag],
            else: []
          )

      {:ok, {agent.command, args}}
    end
  end

  @doc "Returns the list of built-in agent definitions."
  @spec builtin_agents() :: [AgentDef.t()]
  def builtin_agents, do: @builtin_agents

  @doc "Returns custom agents loaded from application configuration."
  @spec custom_agents() :: [AgentDef.t()]
  def custom_agents do
    config = Application.get_env(:symphony_v2, __MODULE__, [])
    raw_agents = Keyword.get(config, :custom_agents, [])

    raw_agents
    |> Enum.map(&AgentDef.new/1)
    |> Enum.flat_map(fn
      {:ok, agent} -> [agent]
      {:error, _} -> []
    end)
  end
end
