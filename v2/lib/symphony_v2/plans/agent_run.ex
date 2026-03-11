defmodule SymphonyV2.Plans.AgentRun do
  @moduledoc """
  Schema for agent runs. Each agent run tracks a single execution attempt
  of an agent against a subtask, including output logs and timing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyV2.Plans.Subtask

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running succeeded failed timeout)

  schema "agent_runs" do
    field :agent_type, :string
    field :attempt_number, :integer
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :exit_code, :integer
    field :stdout_log_path, :string
    field :stderr_log_path, :string
    field :duration_ms, :integer
    field :error_message, :string

    belongs_to :subtask, Subtask

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid agent run statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for creating a new agent run."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [:subtask_id, :agent_type, :attempt_number, :started_at])
    |> validate_required([:agent_type, :attempt_number, :started_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_type, Subtask.agent_types())
    |> validate_number(:attempt_number, greater_than: 0)
    |> foreign_key_constraint(:subtask_id)
  end

  @doc "Changeset for completing an agent run (success, failure, or timeout)."
  @spec complete_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def complete_changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [
      :status,
      :completed_at,
      :exit_code,
      :stdout_log_path,
      :stderr_log_path,
      :duration_ms,
      :error_message
    ])
    |> validate_required([:status, :completed_at])
    |> validate_inclusion(:status, @statuses)
  end
end
