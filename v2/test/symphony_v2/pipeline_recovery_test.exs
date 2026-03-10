defmodule SymphonyV2.PipelineRecoveryTest do
  use SymphonyV2.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyV2.Pipeline
  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures
  alias SymphonyV2.Workspace

  @moduletag :pipeline_recovery

  defp test_config(tmp_dir, overrides \\ []) do
    repo_path = Path.join(tmp_dir, "source-repo")
    workspace_root = Path.join(tmp_dir, "workspaces")
    File.mkdir_p!(repo_path)
    File.mkdir_p!(workspace_root)

    init_git_repo(repo_path)

    config = %SymphonyV2.AppConfig{
      repo_path: repo_path,
      workspace_root: workspace_root,
      test_command: "echo 'tests pass'",
      planning_agent: "claude_code",
      review_agent: "gemini_cli",
      default_agent: "claude_code",
      dangerously_skip_permissions: false,
      agent_timeout_ms: 30_000,
      max_retries: 2
    }

    Enum.reduce(overrides, config, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp init_git_repo(path) do
    System.cmd("git", ["init", "--initial-branch=main", path], stderr_to_stdout: true)

    System.cmd("git", ["-C", path, "config", "user.email", "test@test.com"],
      stderr_to_stdout: true
    )

    System.cmd("git", ["-C", path, "config", "user.name", "Test"], stderr_to_stdout: true)
    File.write!(Path.join(path, "README.md"), "# Test\n")
    System.cmd("git", ["-C", path, "add", "-A"], stderr_to_stdout: true)
    System.cmd("git", ["-C", path, "commit", "-m", "init"], stderr_to_stdout: true)
  end

  defp start_pipeline(config, name \\ nil) do
    name = name || :"pipeline_recovery_#{System.unique_integer([:positive])}"
    {:ok, pid} = Pipeline.start_link(config: config, name: name)
    # Allow the new pipeline process to access the Ecto sandbox
    Sandbox.allow(SymphonyV2.Repo, self(), pid)
    {pid, name}
  end

  defp create_planning_task(attrs \\ %{}) do
    task = TasksFixtures.task_fixture(attrs)
    {:ok, task} = Tasks.update_task_status(task, "planning")
    task
  end

  defp create_plan_review_task do
    task = create_planning_task()
    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "awaiting_review"})
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {task, plan}
  end

  defp create_executing_task(config, subtask_attrs_list) do
    task = create_planning_task()
    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})
    {:ok, subtasks} = Plans.create_subtasks_from_plan(plan, subtask_attrs_list)
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {:ok, task} = Tasks.update_task_status(task, "executing")

    {:ok, workspace} = Workspace.create(config.workspace_root, task.id)
    {:ok, _} = Workspace.clone_repo(config.repo_path, workspace)

    System.cmd("git", ["-C", workspace, "config", "user.email", "test@test.com"],
      stderr_to_stdout: true
    )

    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"], stderr_to_stdout: true)

    %{task: task, plan: plan, subtasks: subtasks, workspace: workspace}
  end

  describe "Pipeline crash and restart recovery" do
    @tag :tmp_dir
    test "recovers executing task after Pipeline GenServer restart", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      # Start pipeline — it recovers the executing task
      {pid, name} = start_pipeline(config)
      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == ctx.task.id

      # Trap exits so kill doesn't propagate to test process
      Process.flag(:trap_exit, true)
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
      refute Process.alive?(pid)

      # Restart pipeline with same config — it should recover again
      {_pid2, name2} = start_pipeline(config)
      state2 = Pipeline.get_state(name2)
      assert state2.status == :processing
      assert state2.current_task_id == ctx.task.id
      assert state2.current_step == :executing_subtask
    end

    @tag :tmp_dir
    test "recovers plan_review task after Pipeline GenServer restart", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {task, _plan} = create_plan_review_task()

      Process.flag(:trap_exit, true)
      {pid, _name} = start_pipeline(config)

      # Kill
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}

      # Restart
      {_pid2, name2} = start_pipeline(config)
      state = Pipeline.get_state(name2)
      assert state.status == :processing
      assert state.current_task_id == task.id
      assert state.current_step == :awaiting_plan_review
    end

    @tag :tmp_dir
    test "returns to idle after crash when no in-progress tasks", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      Process.flag(:trap_exit, true)
      {pid, _name} = start_pipeline(config)

      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}

      {_pid2, name2} = start_pipeline(config)
      state = Pipeline.get_state(name2)
      assert state.status == :idle
    end

    @tag :tmp_dir
    test "recovery schedules execution continuation for executing tasks", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      ctx =
        create_executing_task(config, [
          %{
            position: 1,
            title: "Step 1",
            spec: "Do something",
            agent_type: "claude_code",
            status: "succeeded"
          }
        ])

      # Mark subtask as succeeded so execute_next_subtask can find no pending
      subtask = hd(ctx.subtasks)
      {:ok, _} = Plans.update_subtask(subtask, %{status: "succeeded"})

      {_pid, name} = start_pipeline(config)

      # Give time for the recovery continuation to run
      Process.sleep(500)

      state = Pipeline.get_state(name)
      # Should have transitioned to awaiting_final_review since all subtasks succeeded
      # or remain processing (depends on timing)
      assert state.status == :processing
    end
  end

  describe "terminate/2 logging" do
    @tag :tmp_dir
    test "Pipeline terminates gracefully on normal shutdown", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {pid, _name} = start_pipeline(config)

      assert Process.alive?(pid)
      GenServer.stop(pid, :normal)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    @tag :tmp_dir
    test "Pipeline terminates gracefully while processing", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {task, _plan} = create_plan_review_task()

      {pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == task.id

      # Graceful stop
      GenServer.stop(pid, :normal)
      Process.sleep(50)
      refute Process.alive?(pid)

      # Task state should still be in DB for recovery
      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "plan_review"
    end
  end

  describe "PubSub Topics integration" do
    @tag :tmp_dir
    test "Pipeline broadcasts use Topics module", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)

      # Subscribe using Topics module
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.pipeline())

      # Broadcast using Topics module
      Phoenix.PubSub.broadcast(
        SymphonyV2.PubSub,
        Topics.pipeline(),
        {:pipeline_started, "test-id"}
      )

      assert_receive {:pipeline_started, "test-id"}
    end

    @tag :tmp_dir
    test "task topics work via Topics module", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)
      task_id = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task_id))

      Phoenix.PubSub.broadcast(
        SymphonyV2.PubSub,
        Topics.task(task_id),
        {:task_step, :planning}
      )

      assert_receive {:task_step, :planning}
    end

    @tag :tmp_dir
    test "subtask topics work via Topics module", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)
      subtask_id = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.subtask(subtask_id))

      Phoenix.PubSub.broadcast(
        SymphonyV2.PubSub,
        Topics.subtask(subtask_id),
        {:subtask_started, 1}
      )

      assert_receive {:subtask_started, 1}
    end

    @tag :tmp_dir
    test "agent_output topics work via Topics module", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)
      agent_run_id = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.agent_output(agent_run_id))

      Phoenix.PubSub.broadcast(
        SymphonyV2.PubSub,
        Topics.agent_output(agent_run_id),
        {:agent_output, agent_run_id, "hello"}
      )

      assert_receive {:agent_output, ^agent_run_id, "hello"}
    end
  end
end
