defmodule SymphonyV2.Plans.ExecutionPlanTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Plans.ExecutionPlan

  import SymphonyV2.TasksFixtures

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      task = task_fixture()

      changeset =
        ExecutionPlan.create_changeset(%ExecutionPlan{}, %{
          task_id: task.id,
          raw_plan: %{"tasks" => []}
        })

      assert changeset.valid?
    end

    test "requires task_id" do
      changeset = ExecutionPlan.create_changeset(%ExecutionPlan{}, %{})
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults status to planning" do
      task = task_fixture()

      changeset =
        ExecutionPlan.create_changeset(%ExecutionPlan{}, %{task_id: task.id})

      assert get_field(changeset, :status) == "planning"
    end

    test "rejects invalid status" do
      task = task_fixture()

      changeset =
        ExecutionPlan.create_changeset(%ExecutionPlan{}, %{
          task_id: task.id,
          status: "invalid"
        })

      assert %{status: [_]} = errors_on(changeset)
    end

    test "enforces unique task_id constraint" do
      task = task_fixture()

      {:ok, _plan} =
        %ExecutionPlan{}
        |> ExecutionPlan.create_changeset(%{task_id: task.id})
        |> SymphonyV2.Repo.insert()

      {:error, changeset} =
        %ExecutionPlan{}
        |> ExecutionPlan.create_changeset(%{task_id: task.id})
        |> SymphonyV2.Repo.insert()

      assert %{task_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "status_changeset/2" do
    test "allows valid status update" do
      plan = %ExecutionPlan{status: "planning"}
      changeset = ExecutionPlan.status_changeset(plan, "executing")
      assert changeset.valid?
      assert get_change(changeset, :status) == "executing"
    end

    test "rejects invalid status" do
      plan = %ExecutionPlan{status: "planning"}
      changeset = ExecutionPlan.status_changeset(plan, "bogus")
      refute changeset.valid?
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      statuses = ExecutionPlan.statuses()
      assert "planning" in statuses
      assert "awaiting_review" in statuses
      assert "executing" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
      assert "plan_review" in statuses
      assert length(statuses) == 6
    end
  end
end
