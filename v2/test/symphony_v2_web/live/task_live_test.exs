defmodule SymphonyV2Web.TaskLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.AccountsFixtures
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures

  setup :register_and_log_in_user

  # --- TaskLive.Index (Steps 149, 148) ---

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
      {:ok, _} = SymphonyV2.Plans.update_plan_status(plan, "executing")
      {:ok, completed_task} = Tasks.update_task_status(completed_task, "plan_review")
      {:ok, completed_task} = Tasks.update_task_status(completed_task, "executing")
      {:ok, _} = Tasks.update_task_status(completed_task, "completed")

      {:ok, view, _html} = live(conn, ~p"/tasks?status=completed")

      assert has_element?(view, "td", "Done Task")
      refute has_element?(view, "td", "Draft Task")
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

      assert has_element?(view, "td", "Clickable Task")
      # Verify the link is present (phx-click with navigate)
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
  end

  # --- TaskLive.New (Steps 150, 143) ---

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

  # --- TaskLive.Show (Steps 151, 145, 152) ---

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

      # Approve button should not be shown for own tasks
      refute has_element?(view, "button", "Approve Task")

      # Direct event should not change the status
      render_click(view, "approve_review")

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "awaiting_review"
    end

    test "shows back to tasks link", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}")

      assert html =~ "Back to Tasks"
    end

    test "updates via PubSub when task step changes", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user, title: "Live Update"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}")

      # Simulate a status change and PubSub broadcast
      {:ok, _} = Tasks.update_task_status(task, "planning")
      send(view.pid, {:task_step, :planning})

      html = render(view)
      assert html =~ "Planning"
    end
  end

  # Helper to create an execution plan for a task
  defp create_plan_for_task(task) do
    {:ok, plan} =
      SymphonyV2.Plans.create_plan(%{
        task_id: task.id,
        status: "planning"
      })

    plan
  end
end
