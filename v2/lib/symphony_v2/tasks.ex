defmodule SymphonyV2.Tasks do
  @moduledoc """
  The Tasks context. Public API for creating, listing, and managing tasks.
  """

  import Ecto.Query

  alias SymphonyV2.Repo
  alias SymphonyV2.Tasks.Task

  @doc "Creates a new task for the given creator."
  @spec create_task(map(), %{id: any()}) :: {:ok, %Task{}} | {:error, Ecto.Changeset.t()}
  def create_task(attrs, creator) do
    # Use string key if attrs are string-keyed (e.g. from form params)
    key = if has_string_keys?(attrs), do: "creator_id", else: :creator_id

    %Task{}
    |> Task.create_changeset(Map.put(attrs, key, creator.id))
    |> Repo.insert()
  end

  defp has_string_keys?(map) when map_size(map) == 0, do: false

  defp has_string_keys?(map) do
    map |> Map.keys() |> List.first() |> is_binary()
  end

  @doc "Lists all tasks ordered by insertion time."
  @spec list_tasks() :: [%Task{}]
  def list_tasks do
    Task
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
    |> Repo.preload(:creator)
  end

  @doc "Lists tasks filtered by status."
  @spec list_tasks_by_status(String.t()) :: [%Task{}]
  def list_tasks_by_status(status) do
    Task
    |> where([t], t.status == ^status)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
    |> Repo.preload(:creator)
  end

  @doc "Gets a single task by ID. Raises if not found."
  @spec get_task!(Ecto.UUID.t()) :: %Task{}
  def get_task!(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload([:creator, :reviewer])
  end

  @doc "Updates a task's status, validating the state machine transition."
  @spec update_task_status(%Task{}, String.t()) :: {:ok, %Task{}} | {:error, Ecto.Changeset.t()}
  def update_task_status(task, new_status) do
    task
    |> Task.status_changeset(new_status)
    |> Repo.update()
    |> tap(fn
      {:ok, updated_task} ->
        Phoenix.PubSub.broadcast(
          SymphonyV2.PubSub,
          SymphonyV2.PubSub.Topics.tasks(),
          {:task_status_changed, updated_task.id, new_status}
        )

      _ ->
        :ok
    end)
  end

  @doc """
  Approves a task for review. The approver must not be the task creator.
  Transitions the task from awaiting_review to planning.
  """
  @spec approve_task_review(%Task{}, %{id: any()}) ::
          {:ok, %Task{}} | {:error, Ecto.Changeset.t()} | {:error, :self_review}
  def approve_task_review(task, reviewer) do
    if task.creator_id == reviewer.id do
      {:error, :self_review}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :review,
        Task.review_changeset(task, %{
          reviewer_id: reviewer.id,
          reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      )
      |> Ecto.Multi.update(:status, fn %{review: task} ->
        Task.status_changeset(task, "planning")
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{status: task}} -> {:ok, task}
        {:error, _step, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc "Returns a changeset for tracking task changes in forms."
  @spec change_task(%Task{}, map()) :: Ecto.Changeset.t()
  def change_task(task, attrs \\ %{}) do
    Task.create_changeset(task, attrs)
  end

  @doc "Lists tasks in the queue (planning status), ordered by queue position."
  @spec list_queued_tasks() :: [%Task{}]
  def list_queued_tasks do
    Task
    |> where([t], t.status in ~w(draft awaiting_review planning))
    |> order_by([t], asc_nulls_last: t.queue_position, asc: t.inserted_at)
    |> Repo.all()
    |> Repo.preload(:creator)
  end

  @doc "Returns the next task ready for processing, ordered by queue position."
  @spec next_queued_task() :: %Task{} | nil
  def next_queued_task do
    Task
    |> where([t], t.status == "planning")
    |> order_by([t], asc_nulls_last: t.queue_position, asc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end
end
