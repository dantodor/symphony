defmodule SymphonyV2.Settings.AppSetting do
  @moduledoc """
  Schema for persisted application settings (singleton row).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyV2.Agents.AgentRegistry

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "app_settings" do
    field :test_command, :string, default: "mix test"
    field :planning_agent, :string, default: "claude_code"
    field :review_agent, :string, default: "gemini_cli"
    field :default_agent, :string, default: "claude_code"
    field :dangerously_skip_permissions, :boolean, default: false
    field :agent_timeout_ms, :integer, default: 600_000
    field :max_retries, :integer, default: 2
    field :review_failure_action, :string, default: "auto_approve"
    field :pipeline_paused, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @fields ~w(test_command planning_agent review_agent default_agent
             dangerously_skip_permissions agent_timeout_ms max_retries
             review_failure_action)a

  @review_failure_actions ~w(auto_approve fail)

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = setting, attrs) do
    setting
    |> cast(attrs, @fields)
    |> validate_required([:test_command])
    |> validate_length(:test_command, min: 1)
    |> validate_number(:agent_timeout_ms, greater_than: 0)
    |> validate_number(:max_retries, greater_than_or_equal_to: 0)
    |> validate_agent_type(:planning_agent)
    |> validate_agent_type(:review_agent)
    |> validate_agent_type(:default_agent)
    |> validate_inclusion(:review_failure_action, @review_failure_actions)
  end

  defp validate_agent_type(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if AgentRegistry.registered?(value) do
        []
      else
        [{field, "is not a registered agent type"}]
      end
    end)
  end
end
