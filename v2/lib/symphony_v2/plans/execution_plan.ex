defmodule SymphonyV2.Plans.ExecutionPlan do
  @moduledoc """
  Schema for execution plans. Each task has at most one execution plan
  that contains the ordered list of subtasks to be executed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Tasks.Task

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(planning awaiting_review executing completed failed)

  schema "execution_plans" do
    field :status, :string, default: "planning"
    field :raw_plan, :map
    field :plan_file_path, :string

    belongs_to :task, Task
    has_many :subtasks, Subtask, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid execution plan statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for creating a new execution plan."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:task_id, :status, :raw_plan, :plan_file_path])
    |> validate_required([:task_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:task_id)
    |> foreign_key_constraint(:task_id)
  end

  @doc "Changeset for updating execution plan status."
  @spec status_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def status_changeset(plan, new_status) do
    plan
    |> change(status: new_status)
    |> validate_inclusion(:status, @statuses)
  end
end
