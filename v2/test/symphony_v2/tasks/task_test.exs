defmodule SymphonyV2.Tasks.TaskTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Tasks.Task

  import SymphonyV2.AccountsFixtures

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "Implement auth",
          description: "Add authentication to the app",
          creator_id: creator.id
        })

      assert changeset.valid?
    end

    test "requires title" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          description: "A description",
          creator_id: creator.id
        })

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires description" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "A title",
          creator_id: creator.id
        })

      assert %{description: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires creator_id" do
      changeset =
        Task.create_changeset(%Task{}, %{
          title: "A title",
          description: "A description"
        })

      assert %{creator_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates title length" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: String.duplicate("a", 256),
          description: "A description",
          creator_id: creator.id
        })

      assert %{title: [msg]} = errors_on(changeset)
      assert msg =~ "at most 255"
    end

    test "defaults status to draft" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "Test",
          description: "Test desc",
          creator_id: creator.id
        })

      assert get_field(changeset, :status) == "draft"
    end

    test "defaults review_requested to false" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "Test",
          description: "Test desc",
          creator_id: creator.id
        })

      assert get_field(changeset, :review_requested) == false
    end

    test "accepts review_requested as true" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "Test",
          description: "Test desc",
          creator_id: creator.id,
          review_requested: true
        })

      assert changeset.valid?
      assert get_field(changeset, :review_requested) == true
    end

    test "accepts optional relevant_files" do
      creator = user_fixture()

      changeset =
        Task.create_changeset(%Task{}, %{
          title: "Test",
          description: "Test desc",
          creator_id: creator.id,
          relevant_files: "lib/foo.ex\nlib/bar.ex"
        })

      assert changeset.valid?
      assert get_field(changeset, :relevant_files) == "lib/foo.ex\nlib/bar.ex"
    end
  end

  describe "status_changeset/2" do
    test "allows valid transition" do
      task = %Task{status: "draft"}
      changeset = Task.status_changeset(task, "planning")
      assert changeset.valid?
      assert get_change(changeset, :status) == "planning"
    end

    test "rejects invalid transition" do
      task = %Task{status: "draft"}
      changeset = Task.status_changeset(task, "completed")
      refute changeset.valid?
      assert %{status: [msg]} = errors_on(changeset)
      assert msg =~ "cannot transition from draft to completed"
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      statuses = Task.statuses()
      assert "draft" in statuses
      assert "awaiting_review" in statuses
      assert "planning" in statuses
      assert "plan_review" in statuses
      assert "executing" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
      assert length(statuses) == 7
    end
  end

  describe "queue_changeset/2" do
    test "sets queue_position" do
      task = %Task{}
      changeset = Task.queue_changeset(task, %{queue_position: 5})
      assert changeset.valid?
      assert get_change(changeset, :queue_position) == 5
    end

    test "allows nil queue_position" do
      task = %Task{queue_position: 3}
      changeset = Task.queue_changeset(task, %{queue_position: nil})
      assert changeset.valid?
    end

    test "updates existing queue_position" do
      task = %Task{queue_position: 1}
      changeset = Task.queue_changeset(task, %{queue_position: 10})
      assert changeset.valid?
      assert get_change(changeset, :queue_position) == 10
    end
  end
end
