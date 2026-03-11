defmodule SymphonyV2.PlansTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Plans
  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.Plans.ExecutionPlan
  alias SymphonyV2.PlansFixtures
  alias SymphonyV2.TasksFixtures

  describe "create_plan/1" do
    test "creates an execution plan with valid attributes" do
      task = TasksFixtures.task_fixture()
      attrs = %{task_id: task.id, raw_plan: %{"tasks" => []}}
      assert {:ok, %ExecutionPlan{} = plan} = Plans.create_plan(attrs)
      assert plan.task_id == task.id
      assert plan.status == "planning"
      assert plan.raw_plan == %{"tasks" => []}
    end

    test "fails without required task_id" do
      assert {:error, changeset} = Plans.create_plan(%{})
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails with duplicate task_id" do
      task = TasksFixtures.task_fixture()
      assert {:ok, _plan} = Plans.create_plan(%{task_id: task.id})
      assert {:error, changeset} = Plans.create_plan(%{task_id: task.id})
      assert %{task_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_plan!/1" do
    test "returns the plan with subtasks and agent_runs preloaded" do
      plan = PlansFixtures.execution_plan_fixture()
      _subtask = PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 1})

      fetched = Plans.get_plan!(plan.id)
      assert fetched.id == plan.id
      assert length(fetched.subtasks) == 1
      assert hd(fetched.subtasks).agent_runs == []
    end

    test "raises on not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Plans.get_plan!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_plan_by_task_id/1" do
    test "returns the plan for a task" do
      task = TasksFixtures.task_fixture()
      plan = PlansFixtures.execution_plan_fixture(%{task: task})

      fetched = Plans.get_plan_by_task_id(task.id)
      assert fetched.id == plan.id
    end

    test "returns nil when no plan exists" do
      assert is_nil(Plans.get_plan_by_task_id(Ecto.UUID.generate()))
    end
  end

  describe "update_plan_status/2" do
    test "updates the plan status" do
      plan = PlansFixtures.execution_plan_fixture()
      assert {:ok, updated} = Plans.update_plan_status(plan, "awaiting_review")
      assert updated.status == "awaiting_review"
    end

    test "accepts plan_review status" do
      plan = PlansFixtures.execution_plan_fixture()
      assert {:ok, updated} = Plans.update_plan_status(plan, "plan_review")
      assert updated.status == "plan_review"
    end

    test "rejects invalid status" do
      plan = PlansFixtures.execution_plan_fixture()
      assert {:error, changeset} = Plans.update_plan_status(plan, "nonexistent")
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "create_subtasks_from_plan/2" do
    test "creates multiple subtasks in order" do
      plan = PlansFixtures.execution_plan_fixture()

      subtask_attrs = [
        %{position: 1, title: "First", spec: "Do first thing", agent_type: "claude_code"},
        %{position: 2, title: "Second", spec: "Do second thing", agent_type: "codex"},
        %{position: 3, title: "Third", spec: "Do third thing", agent_type: "gemini_cli"}
      ]

      assert {:ok, subtasks} = Plans.create_subtasks_from_plan(plan, subtask_attrs)
      assert length(subtasks) == 3

      assert Enum.map(subtasks, & &1.position) == [1, 2, 3]
      assert Enum.map(subtasks, & &1.title) == ["First", "Second", "Third"]
      assert Enum.map(subtasks, & &1.agent_type) == ["claude_code", "codex", "gemini_cli"]
    end

    test "fails if any subtask has invalid attributes" do
      plan = PlansFixtures.execution_plan_fixture()

      subtask_attrs = [
        %{position: 1, title: "Valid", spec: "Do something", agent_type: "claude_code"},
        %{position: 2, title: "", spec: "Missing title", agent_type: "claude_code"}
      ]

      assert {:error, changeset} = Plans.create_subtasks_from_plan(plan, subtask_attrs)
      refute changeset.valid?
    end

    test "fails on duplicate positions" do
      plan = PlansFixtures.execution_plan_fixture()

      subtask_attrs = [
        %{position: 1, title: "First", spec: "Spec A", agent_type: "claude_code"},
        %{position: 1, title: "Duplicate", spec: "Spec B", agent_type: "codex"}
      ]

      assert {:error, _changeset} = Plans.create_subtasks_from_plan(plan, subtask_attrs)
    end
  end

  describe "update_subtask/2" do
    test "updates subtask fields" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        branch_name: "symphony/abc/step-1-first",
        pr_url: "https://github.com/org/repo/pull/1",
        pr_number: 1,
        commit_sha: "abc123",
        files_changed: ["lib/foo.ex", "test/foo_test.exs"],
        test_passed: true
      }

      assert {:ok, updated} = Plans.update_subtask(subtask, attrs)
      assert updated.branch_name == "symphony/abc/step-1-first"
      assert updated.pr_number == 1
      assert updated.test_passed == true
      assert updated.files_changed == ["lib/foo.ex", "test/foo_test.exs"]
    end

    test "updates review fields" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        review_verdict: "approved",
        review_reasoning: "Code looks good"
      }

      assert {:ok, updated} = Plans.update_subtask(subtask, attrs)
      assert updated.review_verdict == "approved"
      assert updated.review_reasoning == "Code looks good"
    end
  end

  describe "update_subtask_status/2" do
    test "updates the subtask status for valid transition" do
      subtask = PlansFixtures.subtask_fixture()
      assert {:ok, updated} = Plans.update_subtask_status(subtask, "dispatched")
      assert updated.status == "dispatched"
    end

    test "allows full valid transition chain" do
      subtask = PlansFixtures.subtask_fixture()
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "dispatched")
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "running")
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "testing")
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "in_review")
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "succeeded")
      assert subtask.status == "succeeded"
    end

    test "rejects invalid status value" do
      subtask = PlansFixtures.subtask_fixture()

      assert {:error, {:invalid_transition, "pending", "nonexistent"}} =
               Plans.update_subtask_status(subtask, "nonexistent")
    end

    test "rejects invalid transition from pending to running" do
      subtask = PlansFixtures.subtask_fixture()

      assert {:error, {:invalid_transition, "pending", "running"}} =
               Plans.update_subtask_status(subtask, "running")
    end

    test "rejects invalid transition from pending to succeeded" do
      subtask = PlansFixtures.subtask_fixture()

      assert {:error, {:invalid_transition, "pending", "succeeded"}} =
               Plans.update_subtask_status(subtask, "succeeded")
    end

    test "rejects skipping states" do
      subtask = PlansFixtures.subtask_fixture()
      assert {:ok, subtask} = Plans.update_subtask_status(subtask, "dispatched")

      assert {:error, {:invalid_transition, "dispatched", "testing"}} =
               Plans.update_subtask_status(subtask, "testing")
    end
  end

  describe "reset_subtask_for_retry/2" do
    test "resets a failed subtask to pending" do
      subtask = PlansFixtures.subtask_fixture(%{status: "failed"})
      assert {:ok, reset} = Plans.reset_subtask_for_retry(subtask, "test error")
      assert reset.status == "pending"
      assert reset.retry_count == 1
      assert reset.last_error == "test error"
      assert is_nil(reset.review_verdict)
      assert is_nil(reset.review_reasoning)
      assert is_nil(reset.test_passed)
      assert is_nil(reset.test_output)
    end

    test "resets a succeeded subtask to pending (task-level retry)" do
      subtask = PlansFixtures.subtask_fixture(%{status: "succeeded"})
      assert {:ok, reset} = Plans.reset_subtask_for_retry(subtask)
      assert reset.status == "pending"
      assert reset.retry_count == 1
    end

    test "resets an in_review subtask to pending" do
      subtask = PlansFixtures.subtask_fixture(%{status: "in_review"})
      assert {:ok, reset} = Plans.reset_subtask_for_retry(subtask)
      assert reset.status == "pending"
    end

    test "increments retry_count on each retry" do
      subtask = PlansFixtures.subtask_fixture(%{status: "failed"})
      assert {:ok, subtask} = Plans.reset_subtask_for_retry(subtask, "error 1")
      assert subtask.retry_count == 1

      # Transition back to failed to retry again
      {:ok, subtask} = Plans.update_subtask_status(subtask, "dispatched")
      {:ok, subtask} = Plans.update_subtask_status(subtask, "failed")
      assert {:ok, subtask} = Plans.reset_subtask_for_retry(subtask, "error 2")
      assert subtask.retry_count == 2
      assert subtask.last_error == "error 2"
    end

    test "rejects reset from pending (cannot go pending→pending)" do
      subtask = PlansFixtures.subtask_fixture()

      assert {:error, {:invalid_transition, "pending", "pending"}} =
               Plans.reset_subtask_for_retry(subtask)
    end

    test "rejects reset from running" do
      subtask = PlansFixtures.subtask_fixture(%{status: "running"})

      assert {:error, {:invalid_transition, "running", "pending"}} =
               Plans.reset_subtask_for_retry(subtask)
    end

    test "accepts nil error_message" do
      subtask = PlansFixtures.subtask_fixture(%{status: "failed"})
      assert {:ok, reset} = Plans.reset_subtask_for_retry(subtask)
      assert is_nil(reset.last_error)
    end
  end

  describe "next_pending_subtask/1" do
    test "returns the next pending subtask ordered by position" do
      plan = PlansFixtures.execution_plan_fixture()

      _s1 =
        PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 1, status: "succeeded"})

      s2 = PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 2})
      _s3 = PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 3})

      next = Plans.next_pending_subtask(plan)
      assert next.id == s2.id
      assert next.position == 2
    end

    test "returns nil when no pending subtasks exist" do
      plan = PlansFixtures.execution_plan_fixture()

      _s1 =
        PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 1, status: "succeeded"})

      assert is_nil(Plans.next_pending_subtask(plan))
    end

    test "returns nil for a plan with no subtasks" do
      plan = PlansFixtures.execution_plan_fixture()
      assert is_nil(Plans.next_pending_subtask(plan))
    end
  end

  describe "all_subtasks_succeeded?/1" do
    test "returns true when all subtasks have succeeded" do
      plan = PlansFixtures.execution_plan_fixture()

      _s1 =
        PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 1, status: "succeeded"})

      _s2 =
        PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 2, status: "succeeded"})

      assert Plans.all_subtasks_succeeded?(plan)
    end

    test "returns false when some subtasks are not succeeded" do
      plan = PlansFixtures.execution_plan_fixture()

      _s1 =
        PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 1, status: "succeeded"})

      _s2 = PlansFixtures.subtask_fixture(%{execution_plan: plan, position: 2, status: "pending"})

      refute Plans.all_subtasks_succeeded?(plan)
    end

    test "returns false for a plan with no subtasks" do
      plan = PlansFixtures.execution_plan_fixture()
      refute Plans.all_subtasks_succeeded?(plan)
    end
  end

  describe "create_agent_run/1" do
    test "creates an agent run with valid attributes" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      assert {:ok, %AgentRun{} = run} = Plans.create_agent_run(attrs)
      assert run.subtask_id == subtask.id
      assert run.agent_type == "claude_code"
      assert run.attempt_number == 1
      assert run.status == "running"
    end

    test "fails with invalid attributes" do
      assert {:error, changeset} = Plans.create_agent_run(%{})
      assert %{subtask_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "complete_agent_run/2" do
    test "completes a running agent run with success" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "succeeded",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        exit_code: 0,
        duration_ms: 5000
      }

      assert {:ok, completed} = Plans.complete_agent_run(agent_run, attrs)
      assert completed.status == "succeeded"
      assert completed.exit_code == 0
      assert completed.duration_ms == 5000
    end

    test "completes a running agent run with failure" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "failed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        exit_code: 1,
        duration_ms: 3000,
        error_message: "Agent crashed"
      }

      assert {:ok, completed} = Plans.complete_agent_run(agent_run, attrs)
      assert completed.status == "failed"
      assert completed.exit_code == 1
      assert completed.error_message == "Agent crashed"
    end

    test "completes a running agent run with timeout" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "timeout",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        duration_ms: 600_000,
        error_message: "Agent exceeded timeout"
      }

      assert {:ok, completed} = Plans.complete_agent_run(agent_run, attrs)
      assert completed.status == "timeout"
    end
  end
end
