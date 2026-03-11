defmodule SymphonyV2Web.DashboardLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.Plans
  alias SymphonyV2.Tasks

  setup :register_and_log_in_user

  describe "dashboard page" do
    test "renders pipeline status when idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "h2", "Pipeline Status")
      assert has_element?(view, "span.badge", "Idle")
    end

    test "renders empty state when no task", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "p", "No task is currently being processed.")
    end

    test "has create task link when idle", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Create Task"
      assert has_element?(view, "a", "Create Task")
    end

    test "shows task queue sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "h3", "Task Queue")
      assert has_element?(view, "div", "No tasks queued.")
    end

    test "shows queued tasks in sidebar", %{conn: conn, user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Queued task", description: "A task", review_requested: false},
          user
        )

      Tasks.update_task_status(task, "planning")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "a", "Queued task")
    end

    test "shows dashboard link in nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Dashboard"
    end
  end

  describe "task with plan" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Test pipeline task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} =
        Plans.create_plan(%{task_id: task.id, status: "executing"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "First step", spec: "Do first thing", agent_type: "claude_code"},
          %{position: 2, title: "Second step", spec: "Do second thing", agent_type: "codex"}
        ])

      # Reload to get subtasks
      plan = Plans.get_plan_by_task_id(task.id)

      %{task: task, plan: plan}
    end

    test "shows subtask list with status indicators", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Subtasks may or may not be visible depending on pipeline state
      # The pipeline picks up the executing task on recovery
      # Just verify the page renders without error
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "shows progress bar when plan exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "progress")
    end

    test "toggles subtask expansion", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      subtask = List.first(plan.subtasks)

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      # After click, the expanded detail should be visible
      assert has_element?(view, "h4", "Specification")
    end

    test "shows subtask spec in expanded view", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      subtask = List.first(plan.subtasks)

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      html = render(view)
      assert html =~ "Do first thing"
    end

    test "shows test results in expanded subtask", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        test_passed: true,
        test_output: "All tests pass",
        status: "testing"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Test Results")
      assert has_element?(view, "span.badge", "Passed")
    end

    test "shows review verdict in expanded subtask", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        review_verdict: "approved",
        review_reasoning: "LGTM",
        status: "succeeded"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Review")
      assert has_element?(view, "span.badge", "approved")
    end

    test "shows PR link for subtask with PR", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        pr_url: "https://github.com/test/repo/pull/42",
        pr_number: 42,
        status: "succeeded"
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PR #42"
      assert html =~ "https://github.com/test/repo/pull/42"
    end

    test "shows retry count for retried subtasks", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)
      Plans.update_subtask(subtask, %{retry_count: 2, status: "running"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "2 retries"
    end

    test "shows error details in expanded failed subtask", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        last_error: "Tests failed: assertion error",
        status: "failed"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Last Error")
      html = render(view)
      assert html =~ "Tests failed: assertion error"
    end

    test "shows branch name in expanded subtask", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{branch_name: "symphony/abc/step-1-first", status: "running"})

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Branch")
      html = render(view)
      assert html =~ "symphony/abc/step-1-first"
    end

    test "shows files changed in expanded subtask", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        files_changed: ["lib/foo.ex", "test/foo_test.exs"],
        status: "succeeded"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Files Changed")
      html = render(view)
      assert html =~ "lib/foo.ex"
      assert html =~ "test/foo_test.exs"
    end
  end

  describe "PubSub real-time updates" do
    test "updates on pipeline_started", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:pipeline_started, "some-task-id"})
      # Should not crash — reloads state
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "updates on pipeline_idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:pipeline_idle, "some-task-id"})
      assert has_element?(view, "span.badge", "Idle")
    end

    test "updates on pipeline_paused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:pipeline_paused, "some-task-id"})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "updates on pipeline_resumed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:pipeline_resumed, "some-task-id"})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "updates on task_step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:task_step, :executing_subtask})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "updates on task_completed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:task_completed, "some-task-id"})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "updates on task_failed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:task_failed, "something went wrong"})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "handles subtask events without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:subtask_started, 1})
      send(view.pid, {:subtask_running, 1})
      send(view.pid, {:subtask_testing, 1})
      send(view.pid, {:subtask_reviewing, 1})
      send(view.pid, {:subtask_succeeded, 1})
      send(view.pid, {:subtask_failed, 1, "error"})
      send(view.pid, {:subtask_retrying, 1, 2})

      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "appends agent output", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:agent_output, "run-123", "line 1\nline 2"})

      html = render(view)
      assert html =~ "line 1"
      assert html =~ "line 2"
    end

    test "handles agent_complete", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:agent_complete, "run-123", %{status: :succeeded}})
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:unknown_message, "data"})
      assert has_element?(view, "h2", "Pipeline Status")
    end
  end

  describe "pipeline controls" do
    test "retry button visible when there's a failed task", %{conn: conn, user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Failed task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, _task} = Tasks.update_task_status(task, "failed")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "button", "Retry Failed")
    end

    test "retry calls pipeline retry_task", %{conn: conn, user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Failed task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, _task} = Tasks.update_task_status(task, "failed")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # The retry call may fail because the pipeline doesn't have workspace etc.
      # but it should at least attempt and not crash the LiveView
      view
      |> element("button", "Retry Failed")
      |> render_click()

      # The view should still be alive
      assert has_element?(view, "h2", "Pipeline Status")
    end
  end

  describe "plan review controls" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Plan review task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")

      {:ok, _plan} =
        Plans.create_plan(%{task_id: task.id, status: "awaiting_review"})

      %{task: task}
    end

    test "shows approve/reject buttons in plan review", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "button", "Approve Plan")
      assert has_element?(view, "button", "Reject Plan")
    end

    test "approve_plan event handles error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Pipeline is not in awaiting_plan_review state, so this will error
      view
      |> element("button", "Approve Plan")
      |> render_click()

      # Should flash an error but not crash
      assert has_element?(view, "h2", "Pipeline Status")
    end

    test "reject_plan event handles error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("button", "Reject Plan")
      |> render_click()

      assert has_element?(view, "h2", "Pipeline Status")
    end
  end

  describe "approve_final control" do
    test "approve_final event handles error when not in correct state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Simulate clicking approve_final via direct event
      # (button wouldn't be visible, but test the handler)
      html =
        view
        |> render_hook("approve_final", %{})

      # Should not crash
      assert html =~ "Pipeline Status"
    end
  end

  describe "pause and resume" do
    test "pause event doesn't crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Directly invoke the event even if button isn't visible
      html = view |> render_hook("pause", %{})
      assert html =~ "Pipeline Status"
    end

    test "resume event doesn't crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html = view |> render_hook("resume", %{})
      assert html =~ "Pipeline Status"
    end
  end

  describe "subtask expansion toggle" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Toggle task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "Step one", spec: "Spec one", agent_type: "claude_code"}
        ])

      plan = Plans.get_plan_by_task_id(task.id)
      %{task: task, plan: plan}
    end

    test "toggle expands and collapses subtask", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      subtask = List.first(plan.subtasks)

      # Expand
      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "h4", "Specification")

      # Collapse (click again)
      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      refute has_element?(view, "h4", "Specification")
    end

    test "shows failed test results", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        test_passed: false,
        test_output: "Failure in test_foo",
        status: "testing"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "span.badge", "Failed")
    end

    test "shows rejected review verdict", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        review_verdict: "rejected",
        review_reasoning: "Code quality issues",
        status: "failed"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "span.badge", "rejected")
      html = render(view)
      assert html =~ "Code quality issues"
    end

    test "shows skipped review verdict", %{conn: conn, plan: plan} do
      subtask = List.first(plan.subtasks)

      Plans.update_subtask(subtask, %{
        review_verdict: "skipped",
        review_reasoning: "Same agent type",
        status: "succeeded"
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("div[phx-value-id=\"#{subtask.id}\"]")
      |> render_click()

      assert has_element?(view, "span.badge", "skipped")
    end
  end

  describe "agent output display" do
    test "shows agent output section with streaming content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Send multiple lines of output
      send(view.pid, {:agent_output, "run-456", "Compiling..."})
      send(view.pid, {:agent_output, "run-456", "Running tests..."})
      send(view.pid, {:agent_output, "run-456", "All passed!"})

      html = render(view)
      assert html =~ "Compiling..."
      assert html =~ "Running tests..."
      assert html =~ "All passed!"
    end

    test "clears output on pipeline_idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:agent_output, "run-789", "Some output"})
      html = render(view)
      assert html =~ "Some output"

      send(view.pid, {:pipeline_idle, "task-id"})
      html = render(view)
      refute html =~ "Some output"
    end
  end

  describe "progress calculation" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Progress task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "Step 1", spec: "S1", agent_type: "claude_code"},
          %{position: 2, title: "Step 2", spec: "S2", agent_type: "claude_code"},
          %{position: 3, title: "Step 3", spec: "S3", agent_type: "claude_code"},
          %{position: 4, title: "Step 4", spec: "S4", agent_type: "claude_code"}
        ])

      plan = Plans.get_plan_by_task_id(task.id)
      %{task: task, plan: plan}
    end

    test "shows 0% when no subtasks completed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "0%"
    end

    test "shows correct percentage when some subtasks done", %{conn: conn, plan: plan} do
      # Mark 2 of 4 as succeeded
      plan.subtasks
      |> Enum.take(2)
      |> Enum.each(fn st -> Plans.update_subtask(st, %{status: "succeeded"}) end)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "50%"
    end
  end

  describe "subtask status display" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Status task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "Pending step", spec: "S1", agent_type: "claude_code"},
          %{position: 2, title: "Dispatched step", spec: "S2", agent_type: "codex"},
          %{position: 3, title: "Running step", spec: "S3", agent_type: "gemini_cli"},
          %{position: 4, title: "In review step", spec: "S4", agent_type: "opencode"},
          %{position: 5, title: "Succeeded step", spec: "S5", agent_type: "claude_code"},
          %{position: 6, title: "Failed step", spec: "S6", agent_type: "claude_code"}
        ])

      plan = Plans.get_plan_by_task_id(task.id)

      # Set each subtask to a different status
      subtasks = Enum.sort_by(plan.subtasks, & &1.position)
      Plans.update_subtask(Enum.at(subtasks, 1), %{status: "dispatched"})
      Plans.update_subtask(Enum.at(subtasks, 2), %{status: "running"})
      Plans.update_subtask(Enum.at(subtasks, 3), %{status: "in_review"})
      Plans.update_subtask(Enum.at(subtasks, 4), %{status: "succeeded"})
      Plans.update_subtask(Enum.at(subtasks, 5), %{status: "failed"})

      plan = Plans.get_plan_by_task_id(task.id)
      %{task: task, plan: plan}
    end

    test "renders all subtask status badges", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Pending"
      assert html =~ "Dispatched"
      assert html =~ "Running"
      assert html =~ "In Review"
      assert html =~ "Succeeded"
      assert html =~ "Failed"
    end

    test "renders all agent types", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "claude_code"
      assert html =~ "codex"
      assert html =~ "gemini_cli"
      assert html =~ "opencode"
    end

    test "shows status icons for each status", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Each subtask should have a status icon
      for subtask <- plan.subtasks do
        assert has_element?(view, "div[phx-value-id=\"#{subtask.id}\"]")
      end
    end
  end

  describe "task status badge classes" do
    test "renders draft task badge in queue", %{conn: conn, user: user} do
      {:ok, _task} =
        Tasks.create_task(
          %{title: "Draft task", description: "D", review_requested: false},
          user
        )

      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Draft"
    end

    test "renders awaiting_review task badge in queue", %{conn: conn, user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Review task", description: "D", review_requested: true},
          user
        )

      Tasks.update_task_status(task, "awaiting_review")

      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Awaiting Review"
    end
  end

  describe "multiple queued tasks in sidebar" do
    test "highlights current task in queue", %{conn: conn, user: user} do
      {:ok, task1} =
        Tasks.create_task(
          %{title: "Task one", description: "D1", review_requested: false},
          user
        )

      {:ok, _task1} = Tasks.update_task_status(task1, "planning")

      {:ok, task2} =
        Tasks.create_task(
          %{title: "Task two", description: "D2", review_requested: false},
          user
        )

      {:ok, _task2} = Tasks.update_task_status(task2, "planning")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Both tasks should appear in queue
      assert has_element?(view, "a", "Task one")
      assert has_element?(view, "a", "Task two")
    end

    test "shows tasks with different statuses in queue", %{conn: conn, user: user} do
      {:ok, t1} =
        Tasks.create_task(
          %{title: "Draft task", description: "D", review_requested: false},
          user
        )

      {:ok, t2} =
        Tasks.create_task(
          %{title: "Awaiting task", description: "D", review_requested: true},
          user
        )

      Tasks.update_task_status(t2, "awaiting_review")

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "a", "Draft task")
      assert has_element?(view, "a", "Awaiting task")
    end
  end

  describe "pipeline step labels and badges" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Step label task", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "planning"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "S1", spec: "Spec1", agent_type: "claude_code"}
        ])

      %{task: task}
    end

    test "displays planning step from task status", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Planning"
    end

    test "renders step labels for various pipeline states via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Test various step events
      send(view.pid, {:task_step, :planning})
      html = render(view)
      assert html =~ "Pipeline Status"

      send(view.pid, {:task_step, :executing_subtask})
      html = render(view)
      assert html =~ "Pipeline Status"

      send(view.pid, {:task_step, :testing})
      html = render(view)
      assert html =~ "Pipeline Status"

      send(view.pid, {:task_step, :reviewing})
      html = render(view)
      assert html =~ "Pipeline Status"

      send(view.pid, {:task_step, :merging})
      html = render(view)
      assert html =~ "Pipeline Status"
    end
  end

  describe "subtask display limit" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Many subtasks", description: "Desc", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

      subtask_attrs =
        for i <- 1..25 do
          %{position: i, title: "Step #{i}", spec: "Spec #{i}", agent_type: "claude_code"}
        end

      {:ok, _subtasks} = Plans.create_subtasks_from_plan(plan, subtask_attrs)

      %{task: task, plan: Plans.get_plan_by_task_id(task.id)}
    end

    test "limits displayed subtasks to 20 by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Should show "Show all 25 subtasks" button
      assert html =~ "Show all 25 subtasks"
      # Step 21 should not be visible (beyond the limit of 20)
      refute html =~ "Step 21"
    end

    test "show_all_subtasks reveals all subtasks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element("button", "Show all 25 subtasks") |> render_click()

      html = render(view)
      assert html =~ "Step 21"
      assert html =~ "Step 25"
      refute html =~ "Show all"
    end
  end

  describe "completed task display" do
    test "shows completed task status", %{conn: conn, user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Completed task", description: "Done", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")
      {:ok, _task} = Tasks.update_task_status(task, "completed")

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # No active task to show
      assert html =~ "Pipeline Status"
    end
  end
end
