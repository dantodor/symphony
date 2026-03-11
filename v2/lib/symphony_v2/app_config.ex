defmodule SymphonyV2.AppConfig do
  @moduledoc """
  Typed struct for Symphony v2 runtime configuration.

  Loaded from application environment (`config/runtime.exs` or `config/dev.exs`).
  Validated on access to ensure all required paths exist and are valid.
  """

  alias SymphonyV2.Agents.AgentRegistry

  @type review_failure_action :: :auto_approve | :fail

  @type t :: %__MODULE__{
          repo_path: String.t() | nil,
          workspace_root: String.t() | nil,
          test_command: String.t(),
          planning_agent: String.t(),
          review_agent: String.t(),
          default_agent: String.t(),
          dangerously_skip_permissions: boolean(),
          agent_timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          review_failure_action: review_failure_action()
        }

  @enforce_keys []
  defstruct repo_path: nil,
            workspace_root: nil,
            test_command: "mix test",
            planning_agent: "claude_code",
            review_agent: "gemini_cli",
            default_agent: "claude_code",
            dangerously_skip_permissions: false,
            agent_timeout_ms: 600_000,
            max_retries: 2,
            review_failure_action: :auto_approve

  @doc """
  Loads the application configuration.

  Merges values from three sources (later sources override earlier):
  1. Struct defaults
  2. Application environment (`config/*.exs`)
  3. Database settings (if available)

  Paths (repo_path, workspace_root) come only from application env.
  """
  @spec load() :: t()
  def load do
    config = Application.get_env(:symphony_v2, __MODULE__, [])

    base = %__MODULE__{
      repo_path: Keyword.get(config, :repo_path),
      workspace_root: Keyword.get(config, :workspace_root),
      test_command: Keyword.get(config, :test_command, "mix test"),
      planning_agent: Keyword.get(config, :planning_agent, "claude_code"),
      review_agent: Keyword.get(config, :review_agent, "gemini_cli"),
      default_agent: Keyword.get(config, :default_agent, "claude_code"),
      dangerously_skip_permissions: Keyword.get(config, :dangerously_skip_permissions, false),
      agent_timeout_ms: Keyword.get(config, :agent_timeout_ms, 600_000),
      max_retries: Keyword.get(config, :max_retries, 2),
      review_failure_action: Keyword.get(config, :review_failure_action, :auto_approve)
    }

    merge_db_settings(base)
  end

  defp merge_db_settings(base) do
    case db_settings() do
      nil -> base
      setting -> apply_db_overrides(base, setting)
    end
  rescue
    # DB may not be available during migrations or early startup
    _error -> base
  end

  @db_override_fields ~w(test_command planning_agent review_agent default_agent
                          dangerously_skip_permissions agent_timeout_ms max_retries
                          review_failure_action)a

  defp apply_db_overrides(base, setting) do
    Enum.reduce(@db_override_fields, base, fn field, acc ->
      case Map.get(setting, field) do
        nil -> acc
        value -> Map.put(acc, field, coerce_field(field, value))
      end
    end)
  end

  defp coerce_field(:review_failure_action, value) when is_binary(value) do
    case value do
      "fail" -> :fail
      _ -> :auto_approve
    end
  end

  defp coerce_field(_field, value), do: value

  defp db_settings do
    SymphonyV2.Repo.one(SymphonyV2.Settings.AppSetting)
  end

  @doc """
  Validates the configuration. Returns `{:ok, config}` or `{:error, errors}`
  where errors is a list of validation error strings.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [String.t()]}
  def validate(%__MODULE__{} = config) do
    errors =
      []
      |> validate_repo_path(config)
      |> validate_workspace_root(config)
      |> validate_agent_type(:planning_agent, config.planning_agent)
      |> validate_agent_type(:review_agent, config.review_agent)
      |> validate_agent_type(:default_agent, config.default_agent)
      |> validate_timeout(config)
      |> validate_max_retries(config)
      |> Enum.reverse()

    case errors do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  @doc """
  Loads and validates the configuration in one step.
  Returns `{:ok, config}` or `{:error, errors}`.
  """
  @spec load_and_validate() :: {:ok, t()} | {:error, [String.t()]}
  def load_and_validate do
    load() |> validate()
  end

  defp validate_repo_path(errors, %{repo_path: nil}) do
    ["repo_path is required" | errors]
  end

  defp validate_repo_path(errors, %{repo_path: path}) do
    if File.dir?(path) do
      errors
    else
      ["repo_path does not exist or is not a directory: #{path}" | errors]
    end
  end

  defp validate_workspace_root(errors, %{workspace_root: nil}) do
    ["workspace_root is required" | errors]
  end

  defp validate_workspace_root(errors, %{workspace_root: path}) do
    if File.dir?(path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:write, :read_write] ->
          errors

        _ ->
          ["workspace_root is not writable: #{path}" | errors]
      end
    else
      ["workspace_root does not exist or is not a directory: #{path}" | errors]
    end
  end

  defp validate_agent_type(errors, field, agent_type) do
    if AgentRegistry.registered?(agent_type) do
      errors
    else
      ["#{field} references unknown agent type: #{agent_type}" | errors]
    end
  end

  defp validate_timeout(errors, %{agent_timeout_ms: ms}) when is_integer(ms) and ms > 0 do
    errors
  end

  defp validate_timeout(errors, %{agent_timeout_ms: ms}) do
    ["agent_timeout_ms must be a positive integer, got: #{inspect(ms)}" | errors]
  end

  defp validate_max_retries(errors, %{max_retries: n}) when is_integer(n) and n >= 0 do
    errors
  end

  defp validate_max_retries(errors, %{max_retries: n}) do
    ["max_retries must be a non-negative integer, got: #{inspect(n)}" | errors]
  end
end
