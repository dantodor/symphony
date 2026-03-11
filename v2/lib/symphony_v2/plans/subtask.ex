defmodule SymphonyV2.Plans.Subtask do
  @moduledoc """
  Schema for subtasks within an execution plan. Each subtask represents
  a discrete unit of work to be performed by a coding agent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.Plans.ExecutionPlan

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending dispatched running testing in_review succeeded failed)
  @agent_types ~w(claude_code codex gemini_cli opencode)
  @review_verdicts ~w(approved rejected skipped)

  schema "subtasks" do
    field :position, :integer
    field :title, :string
    field :spec, :string
    field :agent_type, :string
    field :status, :string, default: "pending"
    field :branch_name, :string
    field :pr_url, :string
    field :pr_number, :integer
    field :commit_sha, :string
    field :files_changed, {:array, :string}
    field :test_output, :string
    field :test_passed, :boolean
    field :review_verdict, :string
    field :review_reasoning, :string
    field :retry_count, :integer, default: 0
    field :last_error, :string
    field :lock_version, :integer, default: 1

    belongs_to :execution_plan, ExecutionPlan
    has_many :agent_runs, AgentRun

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid subtask statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Returns the list of valid agent types."
  @spec agent_types() :: [String.t()]
  def agent_types, do: @agent_types

  @doc "Changeset for creating a new subtask."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(subtask, attrs) do
    subtask
    |> cast(attrs, [:execution_plan_id, :position, :title, :spec, :agent_type])
    |> validate_required([:execution_plan_id, :position, :title, :spec, :agent_type])
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:execution_plan_id, :position])
    |> foreign_key_constraint(:execution_plan_id)
  end

  @doc "Changeset for updating subtask fields after agent execution."
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(subtask, attrs) do
    subtask
    |> cast(attrs, [
      :status,
      :branch_name,
      :pr_url,
      :pr_number,
      :commit_sha,
      :files_changed,
      :test_output,
      :test_passed,
      :review_verdict,
      :review_reasoning,
      :retry_count,
      :last_error
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:review_verdict, @review_verdicts)
    |> validate_review_consistency()
  end

  defp validate_review_consistency(changeset) do
    verdict = get_field(changeset, :review_verdict)
    reasoning = get_field(changeset, :review_reasoning)

    if verdict == "rejected" && (is_nil(reasoning) || reasoning == "") do
      add_error(changeset, :review_reasoning, "is required when verdict is rejected")
    else
      changeset
    end
  end

  @doc "Changeset for editing subtask plan fields during plan review."
  @spec edit_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def edit_changeset(subtask, attrs) do
    subtask
    |> cast(attrs, [:title, :spec, :agent_type])
    |> validate_required([:title, :spec, :agent_type])
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_length(:title, min: 1)
    |> validate_length(:spec, min: 1)
    |> optimistic_lock(:lock_version)
  end

  @doc "Changeset for updating subtask status."
  @spec status_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def status_changeset(subtask, new_status) do
    subtask
    |> change(status: new_status)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end
end
