defmodule SymphonyV2.PerformanceTest do
  @moduledoc """
  Performance and stress tests for Symphony v2.

  Step 216: Large agent output — verify no memory issues in AgentProcess/PubSub.
  Step 217: Long-running agent — verify clean timeout and kill.
  """
  use SymphonyV2.DataCase

  alias SymphonyV2.Agents.AgentProcess
  alias SymphonyV2.MockAgentHelper
  alias SymphonyV2.PlansFixtures

  # --- Step 216: Large agent output ---

  describe "large agent output handling" do
    test "AgentProcess handles large stdout without memory issues" do
      workspace =
        Path.join(System.tmp_dir!(), "perf_large_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      # Create agent run record
      agent_run = PlansFixtures.agent_run_fixture()

      # Script that outputs ~1MB of text (10,000 lines of 100 chars)
      script_path = MockAgentHelper.create_large_output_script(workspace, 10_000)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      opts = %{
        agent_type: :claude_code,
        workspace: workspace,
        agent_run_id: agent_run.id,
        prompt: "test",
        caller: self(),
        timeout_ms: 30_000,
        safehouse_opts: [command_override: {script_path, []}]
      }

      {:ok, _pid} = DynamicSupervisor.start_child(supervisor, {AgentProcess, opts})

      # Wait for completion
      assert_receive {:agent_complete, result}, 30_000
      assert result.status == :succeeded
      assert result.exit_code == 0

      # Verify log file was written with output
      assert result.stdout_log_path != nil
      assert File.exists?(result.stdout_log_path)
      log_content = File.read!(result.stdout_log_path)
      assert byte_size(log_content) > 0
    end

    test "PubSub handles streaming of large output" do
      workspace =
        Path.join(System.tmp_dir!(), "perf_pubsub_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      agent_run = PlansFixtures.agent_run_fixture()

      # Subscribe to agent output
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "agent_output:#{agent_run.id}")

      # Script that outputs many lines
      script_path = MockAgentHelper.create_large_output_script(workspace, 1_000)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      opts = %{
        agent_type: :claude_code,
        workspace: workspace,
        agent_run_id: agent_run.id,
        prompt: "test",
        caller: self(),
        timeout_ms: 30_000,
        safehouse_opts: [command_override: {script_path, []}]
      }

      {:ok, _pid} = DynamicSupervisor.start_child(supervisor, {AgentProcess, opts})

      # Wait for at least some output broadcasts
      assert_receive {:agent_output, _, _}, 15_000

      # Wait for completion
      assert_receive {:agent_complete, _, _}, 30_000
    end
  end

  # --- Step 217: Long-running agent timeout ---

  describe "long-running agent timeout" do
    test "agent is killed after timeout with clean status" do
      workspace =
        Path.join(System.tmp_dir!(), "perf_timeout_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      agent_run = PlansFixtures.agent_run_fixture()

      # Script that sleeps for 30 seconds
      script_path = MockAgentHelper.create_slow_script(workspace, 30)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      timeout_ms = 1_000

      opts = %{
        agent_type: :claude_code,
        workspace: workspace,
        agent_run_id: agent_run.id,
        prompt: "test",
        caller: self(),
        timeout_ms: timeout_ms,
        safehouse_opts: [command_override: {script_path, []}]
      }

      {:ok, _pid} = DynamicSupervisor.start_child(supervisor, {AgentProcess, opts})

      # Should receive timeout result before the sleep would have completed
      assert_receive {:agent_complete, result}, timeout_ms + 5_000
      assert result.status == :timeout
    end

    test "timeout agent produces partial output" do
      workspace =
        Path.join(System.tmp_dir!(), "perf_partial_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      agent_run = PlansFixtures.agent_run_fixture()

      # Script that outputs then sleeps
      script_path = Path.join(workspace, "partial_output.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo "Line 1 of output"
      echo "Line 2 of output"
      sleep 30
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      opts = %{
        agent_type: :claude_code,
        workspace: workspace,
        agent_run_id: agent_run.id,
        prompt: "test",
        caller: self(),
        timeout_ms: 2_000,
        safehouse_opts: [command_override: {script_path, []}]
      }

      {:ok, _pid} = DynamicSupervisor.start_child(supervisor, {AgentProcess, opts})

      assert_receive {:agent_complete, result}, 10_000
      assert result.status == :timeout
      # Should have captured partial output before timeout in the log file
      assert result.stdout_log_path != nil
      log_content = File.read!(result.stdout_log_path)
      assert log_content =~ "Line 1"
    end
  end
end
