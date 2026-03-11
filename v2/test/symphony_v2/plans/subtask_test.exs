defmodule SymphonyV2.Plans.SubtaskTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Plans.Subtask

  import SymphonyV2.PlansFixtures

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      plan = execution_plan_fixture()

      changeset =
        Subtask.create_changeset(%Subtask{}, %{
          execution_plan_id: plan.id,
          position: 1,
          title: "Implement feature",
          spec: "Build the thing as described",
          agent_type: "claude_code"
        })

      assert changeset.valid?
    end

    test "requires all mandatory fields" do
      changeset = Subtask.create_changeset(%Subtask{}, %{})

      assert %{
               execution_plan_id: ["can't be blank"],
               position: ["can't be blank"],
               title: ["can't be blank"],
               spec: ["can't be blank"],
               agent_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates agent_type is in allowed list" do
      plan = execution_plan_fixture()

      changeset =
        Subtask.create_changeset(%Subtask{}, %{
          execution_plan_id: plan.id,
          position: 1,
          title: "Test",
          spec: "Test spec",
          agent_type: "unknown_agent"
        })

      assert %{agent_type: [_]} = errors_on(changeset)
    end

    test "accepts all valid agent types" do
      plan = execution_plan_fixture()

      for {agent_type, position} <- Enum.with_index(Subtask.agent_types(), 1) do
        changeset =
          Subtask.create_changeset(%Subtask{}, %{
            execution_plan_id: plan.id,
            position: position,
            title: "Test #{agent_type}",
            spec: "Spec for #{agent_type}",
            agent_type: agent_type
          })

        assert changeset.valid?, "Expected #{agent_type} to be valid"
      end
    end

    test "validates position is greater than 0" do
      plan = execution_plan_fixture()

      changeset =
        Subtask.create_changeset(%Subtask{}, %{
          execution_plan_id: plan.id,
          position: 0,
          title: "Test",
          spec: "Test spec",
          agent_type: "claude_code"
        })

      assert %{position: [_]} = errors_on(changeset)
    end

    test "enforces unique position per plan" do
      plan = execution_plan_fixture()

      {:ok, _subtask} =
        %Subtask{}
        |> Subtask.create_changeset(%{
          execution_plan_id: plan.id,
          position: 1,
          title: "First",
          spec: "First spec",
          agent_type: "claude_code"
        })
        |> SymphonyV2.Repo.insert()

      {:error, changeset} =
        %Subtask{}
        |> Subtask.create_changeset(%{
          execution_plan_id: plan.id,
          position: 1,
          title: "Duplicate",
          spec: "Duplicate spec",
          agent_type: "codex"
        })
        |> SymphonyV2.Repo.insert()

      assert %{execution_plan_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "defaults status to pending" do
      plan = execution_plan_fixture()

      changeset =
        Subtask.create_changeset(%Subtask{}, %{
          execution_plan_id: plan.id,
          position: 1,
          title: "Test",
          spec: "Test spec",
          agent_type: "claude_code"
        })

      assert get_field(changeset, :status) == "pending"
    end
  end

  describe "update_changeset/2" do
    test "updates execution-related fields" do
      subtask = subtask_fixture()

      changeset =
        Subtask.update_changeset(subtask, %{
          status: "running",
          branch_name: "symphony/abc123/step-1-implement",
          retry_count: 1,
          last_error: "Tests failed"
        })

      assert changeset.valid?
    end

    test "validates review_verdict values" do
      subtask = subtask_fixture()

      changeset = Subtask.update_changeset(subtask, %{review_verdict: "approved"})
      assert changeset.valid?

      changeset =
        Subtask.update_changeset(subtask, %{
          review_verdict: "rejected",
          review_reasoning: "Code quality issues"
        })

      assert changeset.valid?

      changeset = Subtask.update_changeset(subtask, %{review_verdict: "maybe"})
      assert %{review_verdict: [_]} = errors_on(changeset)
    end

    test "validates status values" do
      subtask = subtask_fixture()

      changeset = Subtask.update_changeset(subtask, %{status: "invalid"})
      assert %{status: [_]} = errors_on(changeset)
    end
  end

  describe "status_changeset/2" do
    test "allows valid status" do
      subtask = %Subtask{status: "pending"}
      changeset = Subtask.status_changeset(subtask, "running")
      assert changeset.valid?
    end

    test "rejects invalid status" do
      subtask = %Subtask{status: "pending"}
      changeset = Subtask.status_changeset(subtask, "bogus")
      refute changeset.valid?
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      statuses = Subtask.statuses()
      assert "pending" in statuses
      assert "dispatched" in statuses
      assert "running" in statuses
      assert "testing" in statuses
      assert "in_review" in statuses
      assert "succeeded" in statuses
      assert "failed" in statuses
      assert length(statuses) == 7
    end
  end

  describe "update_changeset/2 review consistency" do
    test "rejected verdict requires review_reasoning" do
      subtask = subtask_fixture()

      changeset = Subtask.update_changeset(subtask, %{review_verdict: "rejected"})
      assert %{review_reasoning: ["is required when verdict is rejected"]} = errors_on(changeset)
    end

    test "rejected verdict with empty reasoning is invalid" do
      subtask = subtask_fixture()

      changeset =
        Subtask.update_changeset(subtask, %{review_verdict: "rejected", review_reasoning: ""})

      assert %{review_reasoning: ["is required when verdict is rejected"]} = errors_on(changeset)
    end

    test "rejected verdict with reasoning is valid" do
      subtask = subtask_fixture()

      changeset =
        Subtask.update_changeset(subtask, %{
          review_verdict: "rejected",
          review_reasoning: "Code quality issues"
        })

      assert changeset.valid?
    end

    test "approved verdict does not require reasoning" do
      subtask = subtask_fixture()

      changeset = Subtask.update_changeset(subtask, %{review_verdict: "approved"})
      assert changeset.valid?
    end

    test "skipped verdict does not require reasoning" do
      subtask = subtask_fixture()

      changeset = Subtask.update_changeset(subtask, %{review_verdict: "skipped"})
      assert changeset.valid?
    end
  end

  describe "edit_changeset/2 optimistic locking" do
    test "increments lock_version on update" do
      subtask = subtask_fixture()
      assert subtask.lock_version == 1

      changeset =
        Subtask.edit_changeset(subtask, %{title: "New", spec: "New spec", agent_type: "codex"})

      assert changeset.valid?

      {:ok, updated} = SymphonyV2.Repo.update(changeset)
      assert updated.lock_version == 2
    end

    test "raises on stale entry when lock_version mismatches" do
      subtask = subtask_fixture()

      # Simulate concurrent edit by updating lock_version in DB
      subtask
      |> Ecto.Changeset.change(%{lock_version: 99})
      |> SymphonyV2.Repo.update!()

      # Now try to update with old lock_version — should raise
      changeset =
        Subtask.edit_changeset(subtask, %{title: "Stale", spec: "Stale spec", agent_type: "codex"})

      assert_raise Ecto.StaleEntryError, fn ->
        SymphonyV2.Repo.update(changeset)
      end
    end
  end

  describe "agent_types/0" do
    test "returns all valid agent types" do
      types = Subtask.agent_types()
      assert "claude_code" in types
      assert "codex" in types
      assert "gemini_cli" in types
      assert "opencode" in types
      assert length(types) == 4
    end
  end
end
