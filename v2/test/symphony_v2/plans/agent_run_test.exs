defmodule SymphonyV2.Plans.AgentRunTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Plans.AgentRun
  alias SymphonyV2.PlansFixtures

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert AgentRun.statuses() == ~w(running succeeded failed timeout)
    end
  end

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert changeset.valid?
    end

    test "allows nil subtask_id (orphaned agent runs survive subtask deletion)" do
      attrs = %{agent_type: "claude_code", attempt_number: 1, started_at: DateTime.utc_now()}
      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert changeset.valid?
    end

    test "requires agent_type" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert %{agent_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires attempt_number" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert %{attempt_number: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires started_at" do
      subtask = PlansFixtures.subtask_fixture()
      attrs = %{subtask_id: subtask.id, agent_type: "claude_code", attempt_number: 1}
      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert %{started_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates agent_type inclusion" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "invalid_agent",
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert %{agent_type: ["is invalid"]} = errors_on(changeset)
    end

    test "validates attempt_number is positive" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        attempt_number: 0,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert %{attempt_number: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "defaults status to running" do
      subtask = PlansFixtures.subtask_fixture()

      attrs = %{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "running"
    end

    test "accepts all valid agent types" do
      subtask = PlansFixtures.subtask_fixture()

      for agent_type <- ~w(claude_code codex gemini_cli opencode) do
        attrs = %{
          subtask_id: subtask.id,
          agent_type: agent_type,
          attempt_number: 1,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        changeset = AgentRun.create_changeset(%AgentRun{}, attrs)
        assert changeset.valid?, "Expected #{agent_type} to be valid"
      end
    end
  end

  describe "complete_changeset/2" do
    test "valid completion attributes" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "succeeded",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        exit_code: 0,
        duration_ms: 5000
      }

      changeset = AgentRun.complete_changeset(agent_run, attrs)
      assert changeset.valid?
    end

    test "requires completed_at even when status is provided" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{status: "succeeded"}
      changeset = AgentRun.complete_changeset(agent_run, attrs)
      assert %{completed_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires completed_at" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{status: "succeeded"}
      changeset = AgentRun.complete_changeset(agent_run, attrs)
      assert %{completed_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "invalid",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = AgentRun.complete_changeset(agent_run, attrs)
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts all terminal statuses" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      for status <- ~w(succeeded failed timeout) do
        attrs = %{
          status: status,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        changeset = AgentRun.complete_changeset(agent_run, attrs)
        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end

    test "accepts optional fields" do
      subtask = PlansFixtures.subtask_fixture()
      agent_run = PlansFixtures.agent_run_fixture(%{subtask: subtask})

      attrs = %{
        status: "failed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        exit_code: 1,
        stdout_log_path: "/tmp/logs/stdout.log",
        stderr_log_path: "/tmp/logs/stderr.log",
        duration_ms: 120_000,
        error_message: "Agent timed out"
      }

      changeset = AgentRun.complete_changeset(agent_run, attrs)
      assert changeset.valid?
    end
  end
end
