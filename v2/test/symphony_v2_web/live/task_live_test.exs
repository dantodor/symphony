defmodule SymphonyV2Web.TaskLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.AccountsFixtures
  alias SymphonyV2.Plans
  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Repo
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures

  setup :register_and_log_in_user

  # --- TaskLive.Index ---

  describe "Index" do
    test "lists all tasks", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "My Test Task"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Tasks"
      assert html =~ "My Test Task"
      assert html =~ "New Task"
      assert html =~ user.email
    end

    test "shows empty state when no tasks", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "No tasks found"
    end

    test "filters by status — completed", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Draft Task"})

      completed_task = TasksFixtures.task_fixture(%{creator: user, title: "Done Task"})
      {:ok, completed_task} = Tasks.update_task_status(completed_task, "planning")
      plan = create_plan_for_task(completed_task)
      {:ok, _} = Plans.update_plan_status(plan, "executing")
      {:ok, completed_task} = Tasks.update_task_status(completed_task, "plan_review")
      {:ok, completed_task} = Tasks.update_task_status(completed_task, "executing")
      {:ok, _} = Tasks.update_task_status(completed_task, "completed")

      {:ok, view, _html} = live(conn, ~p"/tasks?status=completed")

      assert has_element?(view, "td", "Done Task")
      refute has_element?(view, "td", "Draft Task")
    end

    test "filters by status — queued", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Draft Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks?status=queued")

      assert has_element?(view, "td", "Draft Task")
    end

    test "filters by status — in_progress", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Executing Task"})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      create_plan_for_task(task)
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, _task} = Tasks.update_task_status(task, "executing")

      {:ok, view, _html} = live(conn, ~p"/tasks?status=in_progress")

      assert has_element?(view, "td", "Executing Task")
    end

    test "filters by status — failed", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Failed Task"})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      {:ok, _task} = Tasks.update_task_status(task, "failed")

      {:ok, view, _html} = live(conn, ~p"/tasks?status=failed")

      assert has_element?(view, "td", "Failed Task")
    end

    test "invalid filter defaults to all", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Some Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks?status=bogus")

      assert has_element?(view, "td", "Some Task")
    end

    test "shows status badges", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Draft Task"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Draft"
    end

    test "shows queue column", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Queued Task"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Queue"
    end

    test "task rows are clickable", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Clickable Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "td[phx-click]", "Clickable Task")
      assert render(view) =~ "/tasks/#{task.id}"
    end

    test "status filter tabs are rendered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "All"
      assert html =~ "Queued"
      assert html =~ "In Progress"
      assert html =~ "Completed"
      assert html =~ "Failed"
    end

    test "filter tabs navigate via patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "a[href=\"/tasks?status=completed\"]", "Completed")
    end

    test "refreshes on pipeline PubSub events", %{conn: conn, user: user} do
      TasksFixtures.task_fixture(%{creator: user, title: "Existing Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "td", "Existing Task")

      # Simulate pipeline events
      send(view.pid, {:pipeline_started, "some-id"})
      assert render(view) =~ "Existing Task"

      send(view.pid, {:pipeline_idle, "some-id"})
      assert render(view) =~ "Existing Task"

      # Unknown messages are handled
      send(view.pid, {:unknown_event, "data"})
      assert render(view) =~ "Existing Task"
    end

    test "refreshes on task_status_changed PubSub event", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Status Change Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "td", "Status Change Task")

      # Simulate task status change event
      send(view.pid, {:task_status_changed, task.id, "planning"})
      assert render(view) =~ "Status Change Task"
    end

    test "task status change broadcasts update task list", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Broadcasting Task"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Change task status — this should broadcast to the "tasks" topic
      {:ok, _} = Tasks.update_task_status(task, "planning")

      # Give PubSub a moment to deliver
      Process.sleep(50)

      html = render(view)
      assert html =~ "Broadcasting Task"
      assert html =~ "Planning"
    end
  end

  # --- TaskLive.New ---

  describe "New" do
    test "renders task creation form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks/new")

      assert html =~ "New Task"
      assert html =~ "Title"
      assert html =~ "Description"
      assert html =~ "Relevant files"
      assert html =~ "Request team review"
      assert html =~ "Create Task"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form", task: %{title: "", description: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates task without review and redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-form",
        task: %{
          title: "New Feature Task",
          description: "Implement the new feature",
          relevant_files: "lib/app.ex",
          review_requested: false
        }
      )
      |> render_submit()

      assert_redirect(view)
    end

    test "creates task with review requested", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-form",
        task: %{
          title: "Review This",
          description: "Needs team review first",
          review_requested: true
        }
      )
      |> render_submit()

      assert_redirect(view)
    end

    test "shows validation errors on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-form", task: %{title: "", description: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  # --- TaskLive.Show ---

  describe "Show" do
    test "displays task details", %{conn: conn, user: user} do
      task =
        TasksFixtures.task_fixture(%{
          creator: user,
          title: "Show Me",
          description: "Details here"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Show Me"
      assert html =~ "Details here"
      assert html =~ user.email
    end

    test "displays relevant files", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, relevant_files: "lib/foo.ex"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "lib/foo.ex"
    end

    test "hides relevant files section when empty", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, relevant_files: ""})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      refute html =~ "Relevant Files"
    end

    test "shows approve button for awaiting_review tasks when different user", %{conn: conn} do
      creator = AccountsFixtures.user_fixture()

      task =
        TasksFixtures.task_fixture(%{
          creator: creator,
          title: "Needs Review",
          review_requested: true
        })

      {:ok, _} = Tasks.update_task_status(task, "awaiting_review")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Approve Task"
    end

    test "does not show approve button for own tasks", %{conn: conn, user: user} do
      task =
        TasksFixtures.task_fixture(%{
          creator: user,
          title: "My Task",
          review_requested: true
        })

      {:ok, _} = Tasks.update_task_status(task, "awaiting_review")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      refute html =~ "Approve Task"
    end

    test "approve review transitions task to planning", %{conn: conn} do
      creator = AccountsFixtures.user_fixture()

      task =
        TasksFixtures.task_fixture(%{
          creator: creator,
          title: "Approve Me",
          review_requested: true
        })

      {:ok, _} = Tasks.update_task_status(task, "awaiting_review")

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      view
      |> element("button", "Approve Task")
      |> render_click()

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "planning"
    end

    test "self-review prevented", %{conn: conn, user: user} do
      task =
        TasksFixtures.task_fixture(%{
          creator: user,
          title: "Self Review",
          review_requested: true
        })

      {:ok, _} = Tasks.update_task_status(task, "awaiting_review")

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      refute has_element?(view, "button", "Approve Task")

      render_click(view, "approve_review")

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "awaiting_review"
    end

    test "shows back to tasks link", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Back to Tasks"
    end

    test "shows execution plan with subtasks", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Planned Task"})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "First Step",
        spec: "Do the first thing",
        agent_type: "claude_code",
        status: "succeeded",
        review_verdict: "approved",
        pr_url: "https://github.com/test/repo/pull/1",
        pr_number: 1
      })

      create_subtask(plan, %{
        position: 2,
        title: "Second Step",
        spec: "Do the second thing",
        agent_type: "codex",
        status: "running"
      })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Execution Plan"
      assert html =~ "First Step"
      assert html =~ "Second Step"
      assert html =~ "claude_code"
      assert html =~ "codex"
      assert html =~ "Succeeded"
      assert html =~ "Running"
      assert html =~ "approved"
      assert html =~ "PR #1"
    end

    test "shows subtask with retry count", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "Retry Step",
        spec: "Retried step",
        agent_type: "claude_code",
        status: "succeeded",
        retry_count: 2
      })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "2"
    end

    test "shows subtask without review verdict", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "No Review",
        spec: "Review not yet done",
        agent_type: "claude_code",
        status: "succeeded"
      })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "No Review"
      assert html =~ "Succeeded"
    end

    test "shows subtask with rejected review", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "Rejected Step",
        spec: "Was rejected",
        agent_type: "claude_code",
        status: "failed",
        review_verdict: "rejected"
      })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "rejected"
    end

    test "shows error details for failed tasks", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Failed Task"})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "Broken Step",
        spec: "This broke",
        agent_type: "claude_code",
        status: "failed",
        last_error: "Agent timed out after 300s"
      })

      {:ok, _task} = Tasks.update_task_status(task, "failed")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "This task has failed"
      assert html =~ "Error Details"
      assert html =~ "Broken Step"
      assert html =~ "Agent timed out after 300s"
    end

    test "shows plan review buttons for plan_review status", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Plan Review Task"})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      create_plan_for_task(task)
      {:ok, _task} = Tasks.update_task_status(task, "plan_review")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Approve Plan"
      assert html =~ "Reject Plan"
    end

    test "approve_plan errors when not in correct state", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "approve_plan")

      # Task status should remain unchanged
      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "reject_plan errors when not in correct state", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "reject_plan")

      # Task status should remain unchanged
      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "approve_final errors when not in correct state", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "approve_final")

      # Task status should remain unchanged
      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "updates via PubSub when task step changes", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Live Update"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      {:ok, _} = Tasks.update_task_status(task, "planning")
      send(view.pid, {:task_step, :planning})

      html = render(view)
      assert html =~ "Planning"
    end

    test "handles task_completed PubSub event", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      send(view.pid, {:task_completed, task.id})

      # Should not crash — view still renders
      assert render(view) =~ task.title
    end

    test "handles task_failed PubSub event", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      send(view.pid, {:task_failed, "something went wrong"})

      # Should not crash — view still renders
      assert render(view) =~ task.title
    end

    test "handles subtask PubSub events", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      subtask =
        create_subtask(plan, %{
          position: 1,
          title: "PubSub Step",
          spec: "Testing events",
          agent_type: "claude_code"
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      # All subtask events should trigger a plan reload
      send(view.pid, {:subtask_started, 1})
      render(view)

      send(view.pid, {:subtask_running, 1})
      render(view)

      send(view.pid, {:subtask_testing, 1})
      render(view)

      send(view.pid, {:subtask_reviewing, 1})
      render(view)

      send(view.pid, {:subtask_succeeded, 1})
      render(view)

      send(view.pid, {:subtask_failed, 1, "error"})
      render(view)

      send(view.pid, {:subtask_retrying, subtask.position, 1})
      html = render(view)

      assert html =~ "PubSub Step"
    end

    test "handles unknown PubSub messages", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      send(view.pid, {:unknown_event, "data"})

      # Should not crash
      assert render(view) =~ task.title
    end

    test "approve_plan guards against stale data — task no longer in plan_review", %{
      conn: conn,
      user: user
    } do
      # Task is in draft, not plan_review
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "approve_plan")

      # Task should remain unchanged — stale data guard kicks in
      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "reject_plan guards against stale data — task no longer in plan_review", %{
      conn: conn,
      user: user
    } do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "reject_plan")

      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "approve_final guards against stale data — task no longer executing", %{
      conn: conn,
      user: user
    } do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      render_click(view, "approve_final")

      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "shows all subtask status badge types", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)

      statuses = ~w(pending dispatched running testing in_review succeeded failed)

      Enum.each(Enum.with_index(statuses, 1), fn {status, idx} ->
        create_subtask(plan, %{
          position: idx,
          title: "Step #{idx}",
          spec: "Spec #{idx}",
          agent_type: "claude_code",
          status: status
        })
      end)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Pending"
      assert html =~ "Dispatched"
      assert html =~ "Running"
      assert html =~ "Testing"
      assert html =~ "In Review"
      assert html =~ "Succeeded"
      assert html =~ "Failed"
    end

    test "shows reviewer info when reviewed", %{conn: conn, user: user} do
      creator = AccountsFixtures.user_fixture()

      task =
        TasksFixtures.task_fixture(%{
          creator: creator,
          review_requested: true
        })

      {:ok, _} = Tasks.update_task_status(task, "awaiting_review")
      {:ok, _} = Tasks.approve_task_review(Tasks.get_task!(task.id), user)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Reviewed by"
      assert html =~ user.email
    end

    test "task without relevant files hides that section", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, relevant_files: nil})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      refute has_element?(view, "h3", "Relevant Files")
    end
  end

  # --- Helpers ---

  defp create_plan_for_task(task) do
    {:ok, plan} =
      Plans.create_plan(%{
        task_id: task.id,
        status: "planning"
      })

    plan
  end

  defp create_subtask(plan, attrs) do
    create_attrs = %{
      execution_plan_id: plan.id,
      position: attrs[:position] || attrs["position"],
      title: attrs[:title] || attrs["title"],
      spec: attrs[:spec] || attrs["spec"],
      agent_type: attrs[:agent_type] || attrs["agent_type"]
    }

    {:ok, subtask} =
      %Subtask{}
      |> Subtask.create_changeset(create_attrs)
      |> Repo.insert()

    # Apply update fields (status, review_verdict, pr_url, etc.) via update_changeset
    update_fields =
      Map.drop(attrs, [:execution_plan_id, :position, :title, :spec, :agent_type])

    if map_size(update_fields) > 0 do
      {:ok, subtask} =
        subtask
        |> Subtask.update_changeset(update_fields)
        |> Repo.update()

      subtask
    else
      subtask
    end
  end
end
