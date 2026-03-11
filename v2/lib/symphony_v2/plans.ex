defmodule SymphonyV2.Plans do
  @moduledoc """
  The Plans context. Public API for creating and managing execution plans,
  subtasks, and agent runs.
  """

  import Ecto.Query

  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.Plans.ExecutionPlan
  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Plans.SubtaskState
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

  @doc "Updates a subtask's status, validating the transition against the state machine."
  @spec update_subtask_status(%Subtask{}, String.t()) ::
          {:ok, %Subtask{}}
          | {:error, Ecto.Changeset.t() | {:invalid_transition, String.t(), String.t()}}
  def update_subtask_status(subtask, new_status) do
    if SubtaskState.valid_transition?(subtask.status, new_status) do
      subtask
      |> Subtask.status_changeset(new_status)
      |> Repo.update()
    else
      {:error, {:invalid_transition, subtask.status, new_status}}
    end
  end

  @doc "Resets a subtask for retry, clearing execution artifacts and setting status to pending."
  @spec reset_subtask_for_retry(%Subtask{}, String.t() | nil) ::
          {:ok, %Subtask{}} | {:error, {:invalid_transition, String.t(), String.t()}}
  def reset_subtask_for_retry(subtask, error_message \\ nil) do
    if SubtaskState.valid_transition?(subtask.status, "pending") do
      subtask
      |> Subtask.update_changeset(%{
        status: "pending",
        retry_count: (subtask.retry_count || 0) + 1,
        last_error: error_message,
        review_verdict: nil,
        review_reasoning: nil,
        test_passed: nil,
        test_output: nil
      })
      |> Repo.update()
    else
      {:error, {:invalid_transition, subtask.status, "pending"}}
    end
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

  # --- Plan Editing ---

  @doc "Updates a subtask's plan fields (title, spec, agent_type) during plan review."
  @spec update_subtask_plan_fields(%Subtask{}, map()) ::
          {:ok, %Subtask{}} | {:error, Ecto.Changeset.t()}
  def update_subtask_plan_fields(subtask, attrs) do
    subtask
    |> Subtask.edit_changeset(attrs)
    |> Repo.update()
  end

  @doc "Gets a subtask by ID."
  @spec get_subtask!(Ecto.UUID.t()) :: %Subtask{}
  def get_subtask!(id) do
    Repo.get!(Subtask, id)
  end

  @doc "Adds a subtask to a plan at the given position, resequencing subsequent subtasks."
  @spec add_subtask_to_plan(%ExecutionPlan{}, map()) ::
          {:ok, %Subtask{}} | {:error, Ecto.Changeset.t()}
  def add_subtask_to_plan(plan, attrs) do
    position = Map.get(attrs, :position) || Map.get(attrs, "position")

    # Normalize all keys to atoms for create_changeset
    normalized_attrs =
      attrs
      |> Enum.into(%{}, fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.put(:execution_plan_id, plan.id)
      |> Map.put(:position, position)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:resequence, fn repo, _changes ->
      {count, _} =
        from(s in Subtask,
          where: s.execution_plan_id == ^plan.id and s.position >= ^position
        )
        |> repo.update_all(inc: [position: 1])

      {:ok, count}
    end)
    |> Ecto.Multi.insert(
      :subtask,
      Subtask.create_changeset(%Subtask{}, normalized_attrs)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{subtask: subtask}} -> {:ok, subtask}
      {:error, :subtask, changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Deletes a subtask and resequences remaining subtasks."
  @spec delete_subtask(%Subtask{}) :: {:ok, %Subtask{}} | {:error, Ecto.Changeset.t()}
  def delete_subtask(subtask) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete(:delete, subtask)
    |> Ecto.Multi.run(:resequence, fn repo, _changes ->
      {count, _} =
        from(s in Subtask,
          where:
            s.execution_plan_id == ^subtask.execution_plan_id and
              s.position > ^subtask.position
        )
        |> repo.update_all(inc: [position: -1])

      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{delete: deleted}} -> {:ok, deleted}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Moves a subtask up (decreases position by 1) by swapping with the subtask above."
  @spec move_subtask_up(%Subtask{}) :: :ok | {:error, :already_first}
  def move_subtask_up(%Subtask{position: 1}), do: {:error, :already_first}

  def move_subtask_up(subtask) do
    swap_subtask_positions(subtask, subtask.position - 1)
  end

  @doc "Moves a subtask down (increases position by 1) by swapping with the subtask below."
  @spec move_subtask_down(%Subtask{}) :: :ok | {:error, :already_last}
  def move_subtask_down(subtask) do
    max_pos =
      Subtask
      |> where([s], s.execution_plan_id == ^subtask.execution_plan_id)
      |> Repo.aggregate(:max, :position)

    if subtask.position >= max_pos do
      {:error, :already_last}
    else
      swap_subtask_positions(subtask, subtask.position + 1)
    end
  end

  defp swap_subtask_positions(subtask, target_position) do
    other =
      Subtask
      |> where(
        [s],
        s.execution_plan_id == ^subtask.execution_plan_id and s.position == ^target_position
      )
      |> Repo.one()

    case other do
      nil ->
        {:error, :no_subtask_at_position}

      other ->
        # Use a temporary position to avoid unique constraint violation
        temp_position = -1

        Ecto.Multi.new()
        |> Ecto.Multi.run(:move_to_temp, fn repo, _changes ->
          {1, _} =
            from(s in Subtask, where: s.id == ^subtask.id)
            |> repo.update_all(set: [position: temp_position])

          {:ok, :moved}
        end)
        |> Ecto.Multi.run(:move_other, fn repo, _changes ->
          {1, _} =
            from(s in Subtask, where: s.id == ^other.id)
            |> repo.update_all(set: [position: subtask.position])

          {:ok, :moved}
        end)
        |> Ecto.Multi.run(:move_to_target, fn repo, _changes ->
          {1, _} =
            from(s in Subtask, where: s.id == ^subtask.id)
            |> repo.update_all(set: [position: target_position])

          {:ok, :moved}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, _} -> :ok
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  @doc "Counts the number of subtasks in a plan."
  @spec subtask_count(%ExecutionPlan{}) :: non_neg_integer()
  def subtask_count(plan) do
    Subtask
    |> where([s], s.execution_plan_id == ^plan.id)
    |> Repo.aggregate(:count)
  end

  # --- Agent Runs ---

  @doc "Returns the latest agent run for a given subtask ID."
  @spec latest_agent_run_for_subtask(Ecto.UUID.t()) :: %AgentRun{} | nil
  def latest_agent_run_for_subtask(subtask_id) do
    AgentRun
    |> where([a], a.subtask_id == ^subtask_id)
    |> order_by([a], desc: a.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

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
