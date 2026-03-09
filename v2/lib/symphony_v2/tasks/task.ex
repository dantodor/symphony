defmodule SymphonyV2.Tasks.Task do
  @moduledoc """
  Schema for top-level tasks that represent work to be decomposed and executed by agents.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyV2.Accounts.User
  alias SymphonyV2.Tasks.TaskState

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft awaiting_review planning plan_review executing completed failed)

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :relevant_files, :string
    field :status, :string, default: "draft"
    field :review_requested, :boolean, default: false
    field :reviewed_at, :utc_datetime
    field :queue_position, :integer

    belongs_to :creator, User, foreign_key: :creator_id, type: :id
    belongs_to :reviewer, User, foreign_key: :reviewer_id, type: :id

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid task statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for creating a new task."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :relevant_files, :review_requested, :creator_id])
    |> validate_required([:title, :description, :creator_id])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:creator_id)
  end

  @doc "Changeset for updating task status with state machine validation."
  @spec status_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def status_changeset(task, new_status) do
    case TaskState.valid_transition?(task.status, new_status) do
      true ->
        task
        |> change(status: new_status)

      false ->
        task
        |> change()
        |> add_error(:status, "cannot transition from #{task.status} to #{new_status}")
    end
  end

  @doc "Changeset for approving a task review."
  @spec review_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def review_changeset(task, attrs) do
    task
    |> cast(attrs, [:reviewer_id, :reviewed_at])
    |> validate_required([:reviewer_id, :reviewed_at])
    |> foreign_key_constraint(:reviewer_id)
  end

  @doc "Changeset for updating queue position."
  @spec queue_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def queue_changeset(task, attrs) do
    task
    |> cast(attrs, [:queue_position])
  end
end
