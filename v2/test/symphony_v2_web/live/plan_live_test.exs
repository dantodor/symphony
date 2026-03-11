defmodule SymphonyV2Web.PlanLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.Plans
  alias SymphonyV2.Plans.Subtask
  alias SymphonyV2.Repo
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures

  setup :register_and_log_in_user

  # --- PlanLive.Show ---

  describe "Show — plan display" do
    test "displays execution plan with subtasks", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/plan")

      assert html =~ "Execution Plan"
      assert html =~ task.title
      assert html =~ "Step 1"
      assert html =~ "claude_code"
      assert html =~ "Step 2"
      assert html =~ "codex"
    end

    test "shows no plan message when plan doesn't exist", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/plan")

      assert html =~ "No execution plan has been generated yet"
    end

    test "shows subtask specs", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/plan")

      assert html =~ "Implement the first feature"
      assert html =~ "Implement the second feature"
    end

    test "shows status badges", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task}/plan")

      assert html =~ "Pending"
      assert html =~ "Plan Review"
    end

    test "links back to task", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, "a[href=\"/tasks/#{task.id}\"]", task.title)
    end
  end

  describe "Show — approve and reject" do
    test "shows approve and reject buttons in plan_review", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, "button", "Approve Plan")
      assert has_element?(view, "button", "Reject")
    end

    test "does not show approve/reject when not in plan_review", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      refute has_element?(view, "button", "Approve Plan")
      refute has_element?(view, "button", "Reject")
    end
  end

  describe "Show — subtask editing" do
    test "shows edit buttons in plan_review", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, "button[title=\"Edit\"]")
    end

    test "clicking edit shows inline form", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      subtask = hd(sorted_subtasks(plan))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="edit_subtask"][phx-value-id="#{subtask.id}"]))
      |> render_click()

      html = render(view)
      assert html =~ "Save"
      assert html =~ "Cancel"
    end

    test "can save edited subtask", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      subtask = hd(sorted_subtasks(plan))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="edit_subtask"][phx-value-id="#{subtask.id}"]))
      |> render_click()

      view
      |> form("form", subtask: %{title: "Updated Title", spec: "Updated spec"})
      |> render_submit()

      html = render(view)
      assert html =~ "Updated Title"
      assert html =~ "Updated spec"

      # Verify DB update
      updated = Plans.get_subtask!(subtask.id)
      assert updated.title == "Updated Title"
      assert updated.spec == "Updated spec"
    end

    test "can change agent type", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      subtask = hd(sorted_subtasks(plan))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="edit_subtask"][phx-value-id="#{subtask.id}"]))
      |> render_click()

      view
      |> form("form", subtask: %{agent_type: "gemini_cli"})
      |> render_submit()

      updated = Plans.get_subtask!(subtask.id)
      assert updated.agent_type == "gemini_cli"
    end

    test "cancel edit returns to view mode", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      subtask = hd(sorted_subtasks(plan))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="edit_subtask"][phx-value-id="#{subtask.id}"]))
      |> render_click()

      assert render(view) =~ "Cancel"

      view |> element(~s(button[phx-click="cancel_edit"])) |> render_click()
      refute render(view) =~ "Cancel"
    end
  end

  describe "Show — subtask reordering" do
    test "shows move buttons", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, ~s(button[title="Move up"]))
      assert has_element?(view, ~s(button[title="Move down"]))
    end

    test "move down swaps positions", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      [first, second] = sorted_subtasks(plan)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="move_down"][phx-value-id="#{first.id}"]))
      |> render_click()

      updated_first = Plans.get_subtask!(first.id)
      updated_second = Plans.get_subtask!(second.id)
      assert updated_first.position == 2
      assert updated_second.position == 1
    end

    test "move up swaps positions", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      [first, second] = sorted_subtasks(plan)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="move_up"][phx-value-id="#{second.id}"]))
      |> render_click()

      updated_first = Plans.get_subtask!(first.id)
      updated_second = Plans.get_subtask!(second.id)
      assert updated_first.position == 2
      assert updated_second.position == 1
    end
  end

  describe "Show — add subtask" do
    test "shows add subtask button in plan_review", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, "button", "Add Subtask")
    end

    test "clicking add shows form", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view |> element("button", "Add Subtask") |> render_click()

      html = render(view)
      assert html =~ "Add Subtask at Position"
    end

    test "can add a new subtask", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view |> element("button", "Add Subtask") |> render_click()

      view
      |> form("form",
        subtask: %{title: "New Step", spec: "Do something new", agent_type: "codex"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "New Step"
      assert html =~ "Do something new"

      # Verify 3 subtasks now exist
      updated_plan = Plans.get_plan_by_task_id(task.id)
      assert length(updated_plan.subtasks) == 3
    end

    test "cancel add hides form", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view |> element("button", "Add Subtask") |> render_click()
      assert render(view) =~ "Add Subtask at Position"

      view |> element("button[phx-click=\"cancel_add\"]") |> render_click()
      refute render(view) =~ "Add Subtask at Position"
    end
  end

  describe "Show — delete subtask" do
    test "shows delete buttons in plan_review", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      assert has_element?(view, ~s(button[title="Remove"]))
    end

    test "can delete a subtask", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      [first, _second] = sorted_subtasks(plan)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="delete_subtask"][phx-value-id="#{first.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "Step 1"

      # Verify resequencing: remaining subtask should be at position 1
      updated_plan = Plans.get_plan_by_task_id(task.id)
      assert length(updated_plan.subtasks) == 1
      remaining = hd(updated_plan.subtasks)
      assert remaining.position == 1
    end
  end

  describe "Show — no edit controls when not in plan_review" do
    test "no edit buttons for executing task", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      {:ok, task} = Tasks.update_task_status(task, "planning")
      plan = create_plan_for_task(task)
      create_subtask(plan, %{position: 1, title: "S1", spec: "Spec 1", agent_type: "claude_code"})
      {:ok, _} = Plans.update_plan_status(plan, "executing")
      {:ok, task} = Tasks.update_task_status(task, "plan_review")
      {:ok, _task} = Tasks.update_task_status(task, "executing")

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      refute has_element?(view, "button[title=\"Edit\"]")
      refute has_element?(view, "button[title=\"Remove\"]")
      refute has_element?(view, "button", "Add Subtask")
    end
  end

  describe "Show — validate events" do
    test "validate_edit updates form", %{conn: conn, user: user} do
      {task, plan} = create_task_with_plan(user)
      subtask = hd(sorted_subtasks(plan))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view
      |> element(~s(button[phx-click="edit_subtask"][phx-value-id="#{subtask.id}"]))
      |> render_click()

      html =
        view
        |> form("form", subtask: %{title: "Validating"})
        |> render_change()

      assert html =~ "Validating"
    end

    test "validate_add updates form", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      view |> element("button", "Add Subtask") |> render_click()

      html =
        view
        |> form("form", subtask: %{title: "New Title"})
        |> render_change()

      assert html =~ "New Title"
    end
  end

  describe "Show — PubSub handlers" do
    test "handles task_step event", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      send(view.pid, {:task_step, :executing})
      assert render(view) =~ "Execution Plan"
    end

    test "handles task_completed event", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      send(view.pid, {:task_completed, task.id})
      assert render(view) =~ "Execution Plan"
    end

    test "handles task_failed event", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      send(view.pid, {:task_failed, "some error"})
      assert render(view) =~ "Execution Plan"
    end

    test "handles subtask PubSub events", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

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

      send(view.pid, {:subtask_retrying, 1, 1})
      html = render(view)

      assert html =~ "Execution Plan"
      assert html =~ "Step 1"
    end

    test "handles unknown messages gracefully", %{conn: conn, user: user} do
      {task, _plan} = create_task_with_plan(user)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      send(view.pid, {:unknown_event, "data"})
      assert render(view) =~ "Execution Plan"
    end
  end

  describe "Show — stale data guards" do
    test "approve_plan guards against task no longer in plan_review", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      # Task is in "draft", not "plan_review"
      render_click(view, "approve_plan")

      assert Tasks.get_task!(task.id).status == "draft"
    end

    test "reject_plan guards against task no longer in plan_review", %{conn: conn, user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task}/plan")

      render_click(view, "reject_plan")

      assert Tasks.get_task!(task.id).status == "draft"
    end
  end

  # --- Plans Context Tests ---

  describe "Plans — plan editing functions" do
    test "update_subtask_plan_fields updates title, spec, agent_type" do
      user = SymphonyV2.AccountsFixtures.user_fixture()
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      subtask =
        create_subtask(plan, %{
          position: 1,
          title: "Original",
          spec: "Original spec",
          agent_type: "claude_code"
        })

      {:ok, updated} =
        Plans.update_subtask_plan_fields(subtask, %{
          title: "Updated",
          spec: "Updated spec",
          agent_type: "codex"
        })

      assert updated.title == "Updated"
      assert updated.spec == "Updated spec"
      assert updated.agent_type == "codex"
    end

    test "add_subtask_to_plan inserts and resequences", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "First",
        spec: "First spec",
        agent_type: "claude_code"
      })

      create_subtask(plan, %{
        position: 2,
        title: "Second",
        spec: "Second spec",
        agent_type: "codex"
      })

      {:ok, new_subtask} =
        Plans.add_subtask_to_plan(plan, %{
          position: 2,
          title: "Inserted",
          spec: "Inserted spec",
          agent_type: "gemini_cli"
        })

      assert new_subtask.position == 2

      # Verify resequencing
      updated_plan = Plans.get_plan_by_task_id(task.id)
      subtasks = Enum.sort_by(updated_plan.subtasks, & &1.position)
      assert length(subtasks) == 3
      assert Enum.map(subtasks, & &1.title) == ["First", "Inserted", "Second"]
      assert Enum.map(subtasks, & &1.position) == [1, 2, 3]
    end

    test "delete_subtask removes and resequences", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      first =
        create_subtask(plan, %{
          position: 1,
          title: "First",
          spec: "Spec 1",
          agent_type: "claude_code"
        })

      _second =
        create_subtask(plan, %{position: 2, title: "Second", spec: "Spec 2", agent_type: "codex"})

      _third =
        create_subtask(plan, %{
          position: 3,
          title: "Third",
          spec: "Spec 3",
          agent_type: "gemini_cli"
        })

      {:ok, _deleted} = Plans.delete_subtask(first)

      updated_plan = Plans.get_plan_by_task_id(task.id)
      subtasks = Enum.sort_by(updated_plan.subtasks, & &1.position)
      assert length(subtasks) == 2
      assert Enum.map(subtasks, & &1.title) == ["Second", "Third"]
      assert Enum.map(subtasks, & &1.position) == [1, 2]
    end

    test "move_subtask_up swaps positions", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      first =
        create_subtask(plan, %{
          position: 1,
          title: "First",
          spec: "Spec 1",
          agent_type: "claude_code"
        })

      second =
        create_subtask(plan, %{position: 2, title: "Second", spec: "Spec 2", agent_type: "codex"})

      :ok = Plans.move_subtask_up(second)

      assert Plans.get_subtask!(first.id).position == 2
      assert Plans.get_subtask!(second.id).position == 1
    end

    test "move_subtask_up returns error for first subtask", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      first =
        create_subtask(plan, %{
          position: 1,
          title: "First",
          spec: "Spec 1",
          agent_type: "claude_code"
        })

      assert {:error, :already_first} = Plans.move_subtask_up(first)
    end

    test "move_subtask_down swaps positions", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      first =
        create_subtask(plan, %{
          position: 1,
          title: "First",
          spec: "Spec 1",
          agent_type: "claude_code"
        })

      second =
        create_subtask(plan, %{position: 2, title: "Second", spec: "Spec 2", agent_type: "codex"})

      :ok = Plans.move_subtask_down(first)

      assert Plans.get_subtask!(first.id).position == 2
      assert Plans.get_subtask!(second.id).position == 1
    end

    test "move_subtask_down returns error for last subtask", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      _first =
        create_subtask(plan, %{
          position: 1,
          title: "First",
          spec: "Spec 1",
          agent_type: "claude_code"
        })

      second =
        create_subtask(plan, %{position: 2, title: "Second", spec: "Spec 2", agent_type: "codex"})

      assert {:error, :already_last} = Plans.move_subtask_down(second)
    end

    test "subtask_count returns number of subtasks", %{user: user} do
      task = TasksFixtures.task_fixture(%{creator: user})
      plan = create_plan_for_task(task)

      create_subtask(plan, %{
        position: 1,
        title: "First",
        spec: "Spec 1",
        agent_type: "claude_code"
      })

      create_subtask(plan, %{position: 2, title: "Second", spec: "Spec 2", agent_type: "codex"})

      assert Plans.subtask_count(plan) == 2
    end
  end

  # --- Helpers ---

  defp create_task_with_plan(user) do
    task = TasksFixtures.task_fixture(%{creator: user})
    {:ok, task} = Tasks.update_task_status(task, "planning")
    plan = create_plan_for_task(task)

    create_subtask(plan, %{
      position: 1,
      title: "Step 1",
      spec: "Implement the first feature",
      agent_type: "claude_code"
    })

    create_subtask(plan, %{
      position: 2,
      title: "Step 2",
      spec: "Implement the second feature",
      agent_type: "codex"
    })

    {:ok, _} = Plans.update_plan_status(plan, "awaiting_review")
    {:ok, task} = Tasks.update_task_status(task, "plan_review")

    plan = Plans.get_plan_by_task_id(task.id)
    {task, plan}
  end

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

    subtask
  end

  defp sorted_subtasks(plan) do
    plan.subtasks |> Enum.sort_by(& &1.position)
  end
end
