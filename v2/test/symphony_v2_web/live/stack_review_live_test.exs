defmodule SymphonyV2Web.StackReviewLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.Plans
  alias SymphonyV2.Tasks

  setup :register_and_log_in_user

  defp create_task_with_prs(%{user: user}) do
    {:ok, task} =
      Tasks.create_task(
        %{title: "Stack review task", description: "A completed task", review_requested: false},
        user
      )

    {:ok, task} = Tasks.update_task_status(task, "planning")
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {:ok, task} = Tasks.update_task_status(task, "executing")

    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

    {:ok, _subtasks} =
      Plans.create_subtasks_from_plan(plan, [
        %{
          position: 1,
          title: "Add auth module",
          spec: "Implement auth",
          agent_type: "claude_code"
        },
        %{position: 2, title: "Add tests", spec: "Write tests", agent_type: "codex"},
        %{position: 3, title: "Update docs", spec: "Update README", agent_type: "gemini_cli"}
      ])

    plan = Plans.get_plan_by_task_id(task.id)
    subtasks = Enum.sort_by(plan.subtasks, & &1.position)

    # Mark all subtasks as succeeded with PR data
    Enum.each(Enum.with_index(subtasks, 1), fn {subtask, i} ->
      Plans.update_subtask(subtask, %{
        status: "succeeded",
        branch_name:
          "symphony/#{task.id}/step-#{i}-#{String.downcase(subtask.title) |> String.replace(" ", "-")}",
        pr_url: "https://github.com/test/repo/pull/#{100 + i}",
        pr_number: 100 + i,
        commit_sha: "abc#{i}def",
        files_changed: ["lib/file_#{i}.ex", "test/file_#{i}_test.exs"],
        review_verdict: "approved",
        review_reasoning: "Looks good for step #{i}"
      })
    end)

    plan = Plans.get_plan_by_task_id(task.id)
    %{task: task, plan: plan}
  end

  describe "stack review page" do
    setup [:create_task_with_prs]

    test "renders page with task title", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "Stack Review"
      assert html =~ task.title
    end

    test "lists all PRs with numbers and titles", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert has_element?(view, "span.badge", "#101")
      assert has_element?(view, "span.badge", "#102")
      assert has_element?(view, "span.badge", "#103")
      assert render(view) =~ "Add auth module"
      assert render(view) =~ "Add tests"
      assert render(view) =~ "Update docs"
    end

    test "shows GitHub links for each PR", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "https://github.com/test/repo/pull/101"
      assert html =~ "https://github.com/test/repo/pull/102"
      assert html =~ "https://github.com/test/repo/pull/103"
      assert html =~ "View on GitHub"
    end

    test "shows base branch for each PR", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      # First PR has base "main"
      assert html =~ "main"
    end

    test "shows files changed count", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "2 files"
    end

    test "shows agent type per PR", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "claude_code"
      assert html =~ "codex"
      assert html =~ "gemini_cli"
    end

    test "shows review verdicts", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      # All are approved
      html = render(view)
      assert html =~ "approved"
      assert html =~ "Looks good for step 1"
    end

    test "shows branch names", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "symphony/"
    end

    test "shows back to task link", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert has_element?(view, "a", "Back to Task")
    end

    test "shows PR count badge", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "3"
    end
  end

  describe "approve and merge" do
    setup [:create_task_with_prs]

    test "shows approve and reject buttons", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert has_element?(view, "button", "Approve & Merge")
      assert has_element?(view, "button", "Reject")
    end

    test "approve_merge calls Pipeline and handles error", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      # Pipeline is not in awaiting_final_review state, so this will error
      view
      |> element("button", "Approve & Merge")
      |> render_click()

      # Should not crash
      assert has_element?(view, "h2", "Pull Requests")
    end
  end

  describe "reject flow" do
    setup [:create_task_with_prs]

    test "shows reject form when clicking reject", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      view
      |> element("button", "Reject")
      |> render_click()

      assert has_element?(view, "textarea[name=\"feedback\"]")
      assert has_element?(view, "button", "Reject with Feedback")
      assert has_element?(view, "button", "Cancel")
    end

    test "cancel hides reject form", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      view |> element("button", "Reject") |> render_click()
      assert has_element?(view, "textarea[name=\"feedback\"]")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "textarea[name=\"feedback\"]")
    end

    test "reject with empty feedback shows error", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      view |> element("button", "Reject") |> render_click()

      view
      |> form("form", %{feedback: ""})
      |> render_submit()

      # View should still be alive and form visible
      assert has_element?(view, "textarea[name=\"feedback\"]")
    end

    test "reject with feedback calls Pipeline and handles error", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      view |> element("button", "Reject") |> render_click()

      view
      |> form("form", %{feedback: "The auth module is incomplete"})
      |> render_submit()

      # Pipeline not in correct state, so it will error but not crash
      assert has_element?(view, "h2", "Pull Requests")
    end
  end

  describe "merge progress via PubSub" do
    setup [:create_task_with_prs]

    test "shows merging status on task_step merging", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      send(view.pid, {:task_step, :merging})

      html = render(view)
      assert html =~ "merging"
    end

    test "shows success on task_completed", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      send(view.pid, {:task_completed, task.id})

      html = render(view)
      assert html =~ "successfully merged"
    end

    test "shows failure on task_failed", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      send(view.pid, {:task_failed, "Rebase conflict on branch step-2"})

      html = render(view)
      assert html =~ "Merge failed"
      assert html =~ "Rebase conflict on branch step-2"
    end

    test "handles task_step events without crash", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      send(view.pid, {:task_step, :executing_subtask})
      send(view.pid, {:task_step, :reviewing})

      assert has_element?(view, "h2", "Pull Requests")
    end

    test "handles unknown messages gracefully", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      send(view.pid, {:unknown_msg, "data"})

      assert has_element?(view, "h2", "Pull Requests")
    end
  end

  describe "no PRs state" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "No PR task", description: "Task without PRs", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")

      {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "Step 1", spec: "Spec 1", agent_type: "claude_code"}
        ])

      %{task: task, plan: plan}
    end

    test "shows empty state when no PRs", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert has_element?(view, "div", "No PRs have been created yet.")
    end
  end

  describe "completed task" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Completed task", description: "Done", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")
      {:ok, task} = Tasks.update_task_status(task, "completed")

      %{task: task}
    end

    test "shows completion message", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "completed and all PRs have been merged"
    end

    test "does not show approve/reject buttons", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      refute has_element?(view, "button", "Approve & Merge")
      refute has_element?(view, "button", "Reject")
    end
  end

  describe "failed task" do
    setup %{user: user} do
      {:ok, task} =
        Tasks.create_task(
          %{title: "Failed task", description: "Failed", review_requested: false},
          user
        )

      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, task} = Tasks.update_task_status(task, "executing")
      {:ok, task} = Tasks.update_task_status(task, "failed")

      %{task: task}
    end

    test "shows failure message", %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/stack-review")

      assert html =~ "task has failed"
    end

    test "does not show approve/reject buttons", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/stack-review")

      refute has_element?(view, "button", "Approve & Merge")
      refute has_element?(view, "button", "Reject")
    end
  end
end
