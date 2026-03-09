defmodule SymphonyV2.TasksTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Tasks
  alias SymphonyV2.Tasks.Task

  import SymphonyV2.AccountsFixtures
  import SymphonyV2.TasksFixtures

  describe "create_task/2" do
    test "creates a task with valid attributes" do
      creator = user_fixture()

      assert {:ok, %Task{} = task} =
               Tasks.create_task(
                 %{title: "Implement feature", description: "Build it well"},
                 creator
               )

      assert task.title == "Implement feature"
      assert task.description == "Build it well"
      assert task.status == "draft"
      assert task.creator_id == creator.id
      assert task.review_requested == false
    end

    test "returns error with invalid attributes" do
      creator = user_fixture()
      assert {:error, changeset} = Tasks.create_task(%{title: ""}, creator)
      refute changeset.valid?
    end
  end

  describe "list_tasks/0" do
    test "returns all tasks" do
      task = task_fixture()
      tasks = Tasks.list_tasks()
      assert length(tasks) == 1
      assert hd(tasks).id == task.id
    end

    test "returns multiple tasks" do
      creator = user_fixture()
      _task1 = task_fixture(%{creator: creator, title: "First"})
      _task2 = task_fixture(%{creator: creator, title: "Second"})

      tasks = Tasks.list_tasks()
      assert length(tasks) == 2
    end
  end

  describe "list_tasks_by_status/1" do
    test "filters tasks by status" do
      creator = user_fixture()
      _draft_task = task_fixture(%{creator: creator})

      planning_task = task_fixture(%{creator: creator})
      {:ok, planning_task} = Tasks.update_task_status(planning_task, "planning")

      draft_tasks = Tasks.list_tasks_by_status("draft")
      assert length(draft_tasks) == 1

      planning_tasks = Tasks.list_tasks_by_status("planning")
      assert length(planning_tasks) == 1
      assert hd(planning_tasks).id == planning_task.id
    end
  end

  describe "get_task!/1" do
    test "returns the task with preloaded associations" do
      task = task_fixture()
      fetched = Tasks.get_task!(task.id)
      assert fetched.id == task.id
      assert %SymphonyV2.Accounts.User{} = fetched.creator
      assert fetched.reviewer == nil
    end

    test "raises on non-existent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_task_status/2" do
    test "allows valid transition" do
      task = task_fixture()
      assert {:ok, updated} = Tasks.update_task_status(task, "planning")
      assert updated.status == "planning"
    end

    test "rejects invalid transition" do
      task = task_fixture()
      assert {:error, changeset} = Tasks.update_task_status(task, "completed")
      assert %{status: [_]} = errors_on(changeset)
    end
  end

  describe "approve_task_review/2" do
    test "approves review by a different user" do
      creator = user_fixture()
      reviewer = user_fixture()

      task = task_fixture(%{creator: creator, review_requested: true})
      {:ok, task} = Tasks.update_task_status(task, "awaiting_review")

      assert {:ok, approved_task} = Tasks.approve_task_review(task, reviewer)
      assert approved_task.status == "planning"
      assert approved_task.reviewer_id == reviewer.id
    end

    test "rejects self-review" do
      creator = user_fixture()
      task = task_fixture(%{creator: creator, review_requested: true})
      {:ok, task} = Tasks.update_task_status(task, "awaiting_review")

      assert {:error, :self_review} = Tasks.approve_task_review(task, creator)
    end
  end

  describe "next_queued_task/0" do
    test "returns the next planning task ordered by queue position" do
      creator = user_fixture()
      task1 = task_fixture(%{creator: creator})
      {:ok, _task1} = Tasks.update_task_status(task1, "planning")

      task2 = task_fixture(%{creator: creator})
      {:ok, _task2} = Tasks.update_task_status(task2, "planning")

      next = Tasks.next_queued_task()
      assert next.id == task1.id
    end

    test "returns nil when no tasks are in planning" do
      _task = task_fixture()
      assert Tasks.next_queued_task() == nil
    end
  end
end
