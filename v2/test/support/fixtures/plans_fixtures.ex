defmodule SymphonyV2.PlansFixtures do
  @moduledoc """
  Test helpers for creating entities via the `SymphonyV2.Plans` context.
  """

  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.Plans.ExecutionPlan
  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Repo
  alias SymphonyV2.TasksFixtures

  def valid_execution_plan_attributes(attrs \\ %{}) do
    task = Map.get_lazy(attrs, :task, fn -> TasksFixtures.task_fixture() end)
    attrs = Map.delete(attrs, :task)

    Enum.into(attrs, %{
      task_id: task.id,
      status: "planning",
      raw_plan: %{"tasks" => []}
    })
  end

  def execution_plan_fixture(attrs \\ %{}) do
    {:ok, plan} =
      %ExecutionPlan{}
      |> ExecutionPlan.create_changeset(valid_execution_plan_attributes(attrs))
      |> Repo.insert()

    plan
  end

  def valid_subtask_attributes(attrs \\ %{}) do
    plan = Map.get_lazy(attrs, :execution_plan, fn -> execution_plan_fixture() end)
    attrs = Map.delete(attrs, :execution_plan)

    Enum.into(attrs, %{
      execution_plan_id: plan.id,
      position: Map.get(attrs, :position, 1),
      title: "Subtask #{System.unique_integer([:positive])}",
      spec: "Implement the feature as described.",
      agent_type: "claude_code"
    })
  end

  def subtask_fixture(attrs \\ %{}) do
    status = Map.get(attrs, :status)
    attrs_without_status = Map.delete(attrs, :status)

    {:ok, subtask} =
      %Subtask{}
      |> Subtask.create_changeset(valid_subtask_attributes(attrs_without_status))
      |> Repo.insert()

    if status && status != "pending" do
      # Use status_changeset directly (bypassing state machine validation)
      # to allow setting arbitrary statuses in test fixtures
      {:ok, subtask} =
        subtask
        |> Subtask.status_changeset(status)
        |> Repo.update()

      subtask
    else
      subtask
    end
  end

  def valid_agent_run_attributes(attrs \\ %{}) do
    subtask = Map.get_lazy(attrs, :subtask, fn -> subtask_fixture() end)
    attrs = Map.delete(attrs, :subtask)

    Enum.into(attrs, %{
      subtask_id: subtask.id,
      agent_type: "claude_code",
      attempt_number: 1,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def agent_run_fixture(attrs \\ %{}) do
    {:ok, agent_run} =
      %AgentRun{}
      |> AgentRun.create_changeset(valid_agent_run_attributes(attrs))
      |> Repo.insert()

    agent_run
  end
end
