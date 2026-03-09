defmodule SymphonyV2.Plans do
  @moduledoc """
  The Plans context. Public API for creating and managing execution plans,
  subtasks, and agent runs.
  """

  import Ecto.Query

  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.Plans.ExecutionPlan
  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Repo

  # --- Execution Plans ---

  @doc "Creates an execution plan for a task."
  @spec create_plan(map()) :: {:ok, %ExecutionPlan{}} | {:error, Ecto.Changeset.t()}
  def create_plan(attrs) do
    %ExecutionPlan{}
    |> ExecutionPlan.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Gets an execution plan by ID with subtasks preloaded."
  @spec get_plan!(Ecto.UUID.t()) :: %ExecutionPlan{}
  def get_plan!(id) do
    ExecutionPlan
    |> Repo.get!(id)
    |> Repo.preload(subtasks: :agent_runs)
  end

  @doc "Gets the execution plan for a given task ID."
  @spec get_plan_by_task_id(Ecto.UUID.t()) :: %ExecutionPlan{} | nil
  def get_plan_by_task_id(task_id) do
    ExecutionPlan
    |> where([p], p.task_id == ^task_id)
    |> Repo.one()
    |> maybe_preload_subtasks()
  end

  defp maybe_preload_subtasks(nil), do: nil
  defp maybe_preload_subtasks(plan), do: Repo.preload(plan, subtasks: :agent_runs)

  @doc "Updates an execution plan's status."
  @spec update_plan_status(%ExecutionPlan{}, String.t()) ::
          {:ok, %ExecutionPlan{}} | {:error, Ecto.Changeset.t()}
  def update_plan_status(plan, new_status) do
    plan
    |> ExecutionPlan.status_changeset(new_status)
    |> Repo.update()
  end

  # --- Subtasks ---

  @doc "Creates subtasks from a list of attribute maps for a given plan."
  @spec create_subtasks_from_plan(%ExecutionPlan{}, [map()]) ::
          {:ok, [%Subtask{}]} | {:error, Ecto.Changeset.t()}
  def create_subtasks_from_plan(plan, subtask_attrs_list) do
    Ecto.Multi.new()
    |> add_subtask_inserts(plan, subtask_attrs_list)
    |> Repo.transaction()
    |> case do
      {:ok, results} ->
        subtasks =
          results
          |> Enum.sort_by(fn {key, _} -> key end)
          |> Enum.map(fn {_, subtask} -> subtask end)

        {:ok, subtasks}

      {:error, _key, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp add_subtask_inserts(multi, plan, subtask_attrs_list) do
    subtask_attrs_list
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {attrs, index}, multi ->
      changeset =
        %Subtask{}
        |> Subtask.create_changeset(Map.put(attrs, :execution_plan_id, plan.id))

      Ecto.Multi.insert(multi, {:subtask, index}, changeset)
    end)
  end

  @doc "Updates a subtask with the given attributes."
  @spec update_subtask(%Subtask{}, map()) :: {:ok, %Subtask{}} | {:error, Ecto.Changeset.t()}
  def update_subtask(subtask, attrs) do
    subtask
    |> Subtask.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Updates a subtask's status."
  @spec update_subtask_status(%Subtask{}, String.t()) ::
          {:ok, %Subtask{}} | {:error, Ecto.Changeset.t()}
  def update_subtask_status(subtask, new_status) do
    subtask
    |> Subtask.status_changeset(new_status)
    |> Repo.update()
  end

  @doc "Returns the next pending subtask for a given plan, ordered by position."
  @spec next_pending_subtask(%ExecutionPlan{}) :: %Subtask{} | nil
  def next_pending_subtask(plan) do
    Subtask
    |> where([s], s.execution_plan_id == ^plan.id and s.status == "pending")
    |> order_by([s], asc: s.position)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns true if all subtasks for a plan have succeeded."
  @spec all_subtasks_succeeded?(%ExecutionPlan{}) :: boolean()
  def all_subtasks_succeeded?(plan) do
    total =
      Subtask
      |> where([s], s.execution_plan_id == ^plan.id)
      |> Repo.aggregate(:count)

    succeeded =
      Subtask
      |> where([s], s.execution_plan_id == ^plan.id and s.status == "succeeded")
      |> Repo.aggregate(:count)

    total > 0 and total == succeeded
  end

  # --- Agent Runs ---

  @doc "Creates a new agent run for a subtask."
  @spec create_agent_run(map()) :: {:ok, %AgentRun{}} | {:error, Ecto.Changeset.t()}
  def create_agent_run(attrs) do
    %AgentRun{}
    |> AgentRun.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Completes an agent run with the given result attributes."
  @spec complete_agent_run(%AgentRun{}, map()) ::
          {:ok, %AgentRun{}} | {:error, Ecto.Changeset.t()}
  def complete_agent_run(agent_run, attrs) do
    agent_run
    |> AgentRun.complete_changeset(attrs)
    |> Repo.update()
  end
end
