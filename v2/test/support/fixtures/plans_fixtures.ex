defmodule SymphonyV2.PlansFixtures do
  @moduledoc """
  Test helpers for creating entities via the `SymphonyV2.Plans` context.
  """

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
    {:ok, subtask} =
      %Subtask{}
      |> Subtask.create_changeset(valid_subtask_attributes(attrs))
      |> Repo.insert()

    subtask
  end
end
