defmodule SymphonyV2.Agents.AgentProcessTest do
  use SymphonyV2.DataCase, async: false

  alias SymphonyV2.Agents.AgentProcess
  alias SymphonyV2.Agents.AgentSupervisor
  alias SymphonyV2.Plans
  alias SymphonyV2.PlansFixtures

  setup do
    # Create a subtask and agent run for the test
    subtask = PlansFixtures.subtask_fixture()
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, agent_run} =
      Plans.create_agent_run(%{
        subtask_id: subtask.id,
        agent_type: "claude_code",
        attempt_number: 1,
        started_at: started_at
      })

    workspace =
      Path.join(System.tmp_dir!(), "symphony_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    %{subtask: subtask, agent_run: agent_run, workspace: workspace}
  end

  describe "successful agent execution" do
    test "runs command, captures output, and persists success", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      run_id = agent_run.id

      # Subscribe to PubSub to verify broadcasts
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "agent_output:#{run_id}")

      {:ok, _pid} =
        start_agent_with_script(workspace, run_id, "echo 'hello world'")

      result = wait_for_completion()

      assert result.agent_run_id == run_id
      assert result.exit_code == 0
      assert result.status == :succeeded
      assert result.duration_ms >= 0
      assert File.exists?(result.stdout_log_path)

      # Verify log file content
      log_content = File.read!(result.stdout_log_path)
      assert log_content =~ "hello world"

      # Verify PubSub output broadcast was received
      assert_received {:agent_output, ^run_id, _output}

      # Verify PubSub completion broadcast
      assert_received {:agent_complete, ^run_id, _completion_result}

      # Verify database persistence
      updated_run = SymphonyV2.Repo.get!(Plans.AgentRun, run_id)
      assert updated_run.status == "succeeded"
      assert updated_run.exit_code == 0
      assert updated_run.duration_ms >= 0
      assert updated_run.stdout_log_path != nil
      assert updated_run.completed_at != nil
    end
  end

  describe "failed agent execution" do
    test "reports failure when command exits non-zero", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      {:ok, _pid} =
        start_agent_with_script(workspace, agent_run.id, "echo 'error output' && exit 1")

      result = wait_for_completion()

      assert result.exit_code == 1
      assert result.status == :failed

      # Verify database persistence
      updated_run = SymphonyV2.Repo.get!(Plans.AgentRun, agent_run.id)
      assert updated_run.status == "failed"
      assert updated_run.exit_code == 1
    end
  end

  describe "timeout handling" do
    test "kills agent and reports timeout after timeout_ms", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      # Use a very short timeout
      {:ok, _pid} =
        start_agent_with_script(workspace, agent_run.id, "sleep 60", timeout_ms: 200)

      result = wait_for_completion(5_000)

      assert result.status == :timeout

      # Verify database persistence
      updated_run = SymphonyV2.Repo.get!(Plans.AgentRun, agent_run.id)
      assert updated_run.status == "timeout"
    end
  end

  describe "PubSub broadcasting" do
    test "broadcasts output lines as they arrive", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      run_id = agent_run.id
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "agent_output:#{run_id}")

      {:ok, _pid} =
        start_agent_with_script(
          workspace,
          run_id,
          "echo 'line1' && echo 'line2' && echo 'line3'"
        )

      _result = wait_for_completion()

      # We should have received at least one output broadcast
      # (lines may be batched together)
      assert_received {:agent_output, ^run_id, _output}
    end
  end

  describe "AgentSupervisor" do
    test "starts agent under supervisor", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      script_path = write_test_script(workspace, "echo 'supervised'")

      {:ok, pid} =
        AgentSupervisor.start_agent(%{
          agent_type: :claude_code,
          workspace: workspace,
          agent_run_id: agent_run.id,
          prompt: "test prompt",
          caller: self(),
          timeout_ms: 10_000,
          safehouse_opts: [command_override: {script_path, []}]
        })

      assert Process.alive?(pid)

      _result = wait_for_completion()
    end

    test "reports running count", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      # Start a supervisor we control
      {:ok, sup} = AgentSupervisor.start_link(name: :"test_sup_#{System.unique_integer()}")

      initial_count = AgentSupervisor.running_count(sup)
      assert initial_count == 0

      script_path = write_test_script(workspace, "sleep 5")

      {:ok, _pid} =
        AgentSupervisor.start_agent(sup, %{
          agent_type: :claude_code,
          workspace: workspace,
          agent_run_id: agent_run.id,
          prompt: "test",
          caller: self(),
          timeout_ms: 200,
          safehouse_opts: [command_override: {script_path, []}]
        })

      assert AgentSupervisor.running_count(sup) == 1

      # Wait for it to complete (via timeout)
      _result = wait_for_completion(5_000)

      # Give the process a moment to terminate
      Process.sleep(100)
      assert AgentSupervisor.running_count(sup) == 0
    end
  end

  describe "multi-line output" do
    test "captures all output to log file", %{
      agent_run: agent_run,
      workspace: workspace
    } do
      script = """
      echo 'line 1'
      echo 'line 2'
      echo 'line 3'
      """

      {:ok, _pid} = start_agent_with_script(workspace, agent_run.id, script)

      result = wait_for_completion()

      log_content = File.read!(result.stdout_log_path)
      assert log_content =~ "line 1"
      assert log_content =~ "line 2"
      assert log_content =~ "line 3"
    end
  end

  # --- Helpers ---

  # Instead of going through safehouse (which may not be installed),
  # we write a test shell script and override the command.
  # We modify AgentProcess to accept a command_override option for testing.
  defp start_agent_with_script(workspace, agent_run_id, script_body, extra_opts \\ []) do
    script_path = write_test_script(workspace, script_body)
    timeout_ms = Keyword.get(extra_opts, :timeout_ms, 10_000)

    AgentProcess.start_link(%{
      agent_type: :claude_code,
      workspace: workspace,
      agent_run_id: agent_run_id,
      prompt: "test prompt",
      caller: self(),
      timeout_ms: timeout_ms,
      safehouse_opts: [command_override: {script_path, []}]
    })
  end

  defp write_test_script(workspace, body) do
    script_path = Path.join(workspace, "test_agent_#{System.unique_integer([:positive])}.sh")
    File.write!(script_path, "#!/bin/bash\n#{body}\n")
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp wait_for_completion(timeout \\ 10_000) do
    receive do
      {:agent_complete, result} -> result
    after
      timeout -> flunk("Timed out waiting for agent completion")
    end
  end
end
