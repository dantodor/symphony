defmodule SymphonyV2.PipelineTest do
  use SymphonyV2.DataCase, async: false

  alias SymphonyV2.Pipeline
  alias SymphonyV2.Plans
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures
  alias SymphonyV2.Workspace

  @moduletag :pipeline

  # Helper to create a config pointing to a temp workspace and repo
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
    name = name || :"pipeline_#{System.unique_integer([:positive])}"
    {:ok, pid} = Pipeline.start_link(config: config, name: name)
    {pid, name}
  end

  defp create_planning_task(attrs \\ %{}) do
    task = TasksFixtures.task_fixture(attrs)
    {:ok, task} = Tasks.update_task_status(task, "planning")
    task
  end

  # Creates a task that's gone through planning and is in plan_review
  defp create_plan_review_task do
    task = create_planning_task()
    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "awaiting_review"})
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {task, plan}
  end

  # Creates a task in executing state with subtasks and a workspace
  defp create_executing_task(config, subtask_attrs_list) do
    task = create_planning_task()
    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})
    {:ok, subtasks} = Plans.create_subtasks_from_plan(plan, subtask_attrs_list)
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {:ok, task} = Tasks.update_task_status(task, "executing")

    # Create workspace
    {:ok, workspace} = Workspace.create(config.workspace_root, task.id)
    {:ok, _} = Workspace.clone_repo(config.repo_path, workspace)

    System.cmd("git", ["-C", workspace, "config", "user.email", "test@test.com"],
      stderr_to_stdout: true
    )

    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"], stderr_to_stdout: true)

    %{task: task, plan: plan, subtasks: subtasks, workspace: workspace}
  end

  # Creates a completed task (full state machine traversal)
  defp create_completed_task do
    task = create_planning_task()
    {:ok, _plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})
    {:ok, task} = Tasks.update_task_status(task, "plan_review")
    {:ok, task} = Tasks.update_task_status(task, "executing")
    {:ok, task} = Tasks.update_task_status(task, "completed")
    task
  end

  describe "init/1" do
    @tag :tmp_dir
    test "starts in idle state", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :idle
      assert state.current_task_id == nil
      assert state.current_step == nil
    end

    @tag :tmp_dir
    test "recovers executing task on startup", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == ctx.task.id
      assert state.current_step == :executing_subtask
      assert state.workspace != nil
    end

    @tag :tmp_dir
    test "recovers plan_review task on startup", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {task, _plan} = create_plan_review_task()

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == task.id
      assert state.current_step == :awaiting_plan_review
    end

    @tag :tmp_dir
    test "recovers planning task on startup", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      task = create_planning_task()

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == task.id
      assert state.current_step == :planning
    end

    @tag :tmp_dir
    test "stays idle when no in-progress tasks", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      _task = create_completed_task()

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.status == :idle
    end

    @tag :tmp_dir
    test "prioritizes executing over planning recovery", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      # Create both a planning and executing task
      _planning_task = create_planning_task()

      ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      # Executing takes priority
      assert state.current_task_id == ctx.task.id
      assert state.current_step == :executing_subtask
    end
  end

  describe "check_queue/1" do
    @tag :tmp_dir
    test "does nothing when no tasks queued", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      Pipeline.check_queue(name)
      Process.sleep(50)

      state = Pipeline.get_state(name)
      assert state.status == :idle
    end

    @tag :tmp_dir
    test "does nothing when already processing", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {task, _plan} = create_plan_review_task()

      {_pid, name} = start_pipeline(config)

      _task2 = create_planning_task()

      Pipeline.check_queue(name)
      Process.sleep(50)

      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == task.id
    end
  end

  describe "approve_plan/1" do
    @tag :tmp_dir
    test "returns error when idle", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      assert {:error, :not_awaiting_plan_review} = Pipeline.approve_plan(name)
    end

    @tag :tmp_dir
    test "returns error when in executing step", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      _ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      {_pid, name} = start_pipeline(config)

      assert {:error, :not_awaiting_plan_review} = Pipeline.approve_plan(name)
    end

    @tag :tmp_dir
    test "succeeds when in awaiting_plan_review", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {task, plan} = create_plan_review_task()

      # Add subtasks to the plan
      {:ok, _subtasks} =
        Plans.create_subtasks_from_plan(plan, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      # Create workspace
      {:ok, ws} = Workspace.create(config.workspace_root, task.id)
      {:ok, _} = Workspace.clone_repo(config.repo_path, ws)

      System.cmd("git", ["-C", ws, "config", "user.email", "test@test.com"],
        stderr_to_stdout: true
      )

      System.cmd("git", ["-C", ws, "config", "user.name", "Test"], stderr_to_stdout: true)

      {_pid, name} = start_pipeline(config)

      # Pipeline recovers in awaiting_plan_review
      state = Pipeline.get_state(name)
      assert state.current_step == :awaiting_plan_review

      # Approve the plan
      assert :ok = Pipeline.approve_plan(name)

      # Wait for processing
      Process.sleep(500)

      # Task should have transitioned to executing (or failed if agent can't start)
      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status in ["executing", "failed"]
    end
  end

  describe "reject_plan/1" do
    @tag :tmp_dir
    test "returns error when idle", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      assert {:error, :not_awaiting_plan_review} = Pipeline.reject_plan(name)
    end
  end

  describe "approve_final/1" do
    @tag :tmp_dir
    test "returns error when idle", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      assert {:error, :not_awaiting_final_review} = Pipeline.approve_final(name)
    end

    @tag :tmp_dir
    test "returns error when in executing step", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      _ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      {_pid, name} = start_pipeline(config)

      assert {:error, :not_awaiting_final_review} = Pipeline.approve_final(name)
    end
  end

  describe "get_state/1" do
    @tag :tmp_dir
    test "returns pipeline state without config", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      refute Map.has_key?(state, :config)
      assert Map.has_key?(state, :status)
      assert Map.has_key?(state, :current_task_id)
      assert Map.has_key?(state, :current_step)
      assert Map.has_key?(state, :current_subtask_id)
      assert Map.has_key?(state, :workspace)
    end

    @tag :tmp_dir
    test "returns workspace path when processing", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)

      ctx =
        create_executing_task(config, [
          %{position: 1, title: "Step 1", spec: "Do something", agent_type: "claude_code"}
        ])

      {_pid, name} = start_pipeline(config)

      state = Pipeline.get_state(name)
      assert state.workspace != nil
      assert state.workspace =~ "task-#{ctx.task.id}"
    end
  end

  describe "PubSub broadcasts" do
    @tag :tmp_dir
    test "subscribing to pipeline topic receives messages", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)

      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "pipeline")
      Phoenix.PubSub.broadcast(SymphonyV2.PubSub, "pipeline", {:test_message, :hello})

      assert_receive {:test_message, :hello}
    end

    @tag :tmp_dir
    test "subscribing to task topic receives messages", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      task = create_planning_task()

      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "task:#{task.id}")
      Phoenix.PubSub.broadcast(SymphonyV2.PubSub, "task:#{task.id}", {:test_msg, :task_event})

      assert_receive {:test_msg, :task_event}

      # Clean up — pipeline will recover this task
      {_pid, _name} = start_pipeline(config)
    end

    @tag :tmp_dir
    test "subscribing to subtask topic receives messages", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {_pid, _name} = start_pipeline(config)

      subtask_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, "subtask:#{subtask_id}")

      Phoenix.PubSub.broadcast(
        SymphonyV2.PubSub,
        "subtask:#{subtask_id}",
        {:subtask_started, 1}
      )

      assert_receive {:subtask_started, 1}
    end
  end

  describe "dangerously_skip_permissions" do
    @tag :tmp_dir
    test "config flag is stored correctly", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir, dangerously_skip_permissions: true)
      assert config.dangerously_skip_permissions == true

      {_pid, name} = start_pipeline(config)
      state = Pipeline.get_state(name)
      assert state.status in [:idle, :processing]
    end
  end

  describe "handle_info/2" do
    @tag :tmp_dir
    test "continue check_queue triggers queue check", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir)
      {pid, name} = start_pipeline(config)

      send(pid, {:continue, :check_queue})
      Process.sleep(50)

      state = Pipeline.get_state(name)
      assert state.status == :idle
    end

    @tag :tmp_dir
    test "continue execute_next_subtask with no task stays processing", %{tmp_dir: tmp_dir} do
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

      # Mark subtask as succeeded
      subtask = hd(ctx.subtasks)
      {:ok, _} = Plans.update_subtask(subtask, %{status: "succeeded"})

      {_pid, name} = start_pipeline(config)

      # Pipeline should recover and find all subtasks succeeded
      state = Pipeline.get_state(name)
      assert state.status == :processing
      assert state.current_task_id == ctx.task.id
    end
  end

  describe "error handling" do
    @tag :tmp_dir
    test "invalid workspace root causes task failure on check_queue", %{tmp_dir: tmp_dir} do
      config = test_config(tmp_dir, workspace_root: "/nonexistent/workspace/root")

      # Don't create any tasks — the pipeline starts idle
      {_pid, name} = start_pipeline(config)

      # Now create a task and check queue
      task = create_planning_task()

      Pipeline.check_queue(name)
      Process.sleep(1000)

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"

      state = Pipeline.get_state(name)
      assert state.status == :idle
    end
  end
end
