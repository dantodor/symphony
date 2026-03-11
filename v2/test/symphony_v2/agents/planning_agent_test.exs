defmodule SymphonyV2.Agents.PlanningAgentTest do
  use SymphonyV2.DataCase

  alias SymphonyV2.Agents.PlanningAgent
  alias SymphonyV2.Plans
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures

  setup do
    task = TasksFixtures.task_fixture()

    # Transition task to planning state
    {:ok, task} = Tasks.update_task_status(task, "planning")

    workspace =
      Path.join(System.tmp_dir!(), "planning_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{task: task, workspace: workspace}
  end

  describe "build_prompt/1" do
    test "includes task title and description", %{task: task} do
      prompt = PlanningAgent.build_prompt(task)

      assert prompt =~ task.title
      assert prompt =~ task.description
    end

    test "includes relevant files when present", %{task: task} do
      prompt = PlanningAgent.build_prompt(task)
      assert prompt =~ task.relevant_files
    end

    test "includes available agent types" do
      task = TasksFixtures.task_fixture()
      prompt = PlanningAgent.build_prompt(task)

      assert prompt =~ "claude_code"
      assert prompt =~ "codex"
      assert prompt =~ "gemini_cli"
      assert prompt =~ "opencode"
    end

    test "includes plan.json instructions" do
      task = TasksFixtures.task_fixture()
      prompt = PlanningAgent.build_prompt(task)

      assert prompt =~ "plan.json"
      assert prompt =~ "position"
      assert prompt =~ "agent_type"
    end

    test "handles nil relevant_files" do
      task = TasksFixtures.task_fixture(%{relevant_files: nil})
      prompt = PlanningAgent.build_prompt(task)

      assert prompt =~ task.title
      refute prompt =~ "Relevant files"
    end
  end

  describe "plan_file_path/1" do
    test "returns correct path" do
      assert PlanningAgent.plan_file_path("/workspace") == "/workspace/plan.json"
    end
  end

  describe "run/3 with mock agent" do
    test "succeeds when agent writes valid plan.json", %{task: task, workspace: workspace} do
      # Write a valid plan.json to the workspace (simulating agent output)
      plan_data = %{
        "tasks" => [
          %{
            "position" => 1,
            "title" => "Create schema",
            "spec" => "Create the Ecto schema",
            "agent_type" => "claude_code"
          },
          %{
            "position" => 2,
            "title" => "Add tests",
            "spec" => "Write tests for the schema",
            "agent_type" => "codex"
          }
        ]
      }

      # Create a script that writes plan.json
      script_path = Path.join(workspace, "planning_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "plan.json")} << 'PLAN_EOF'
      #{Jason.encode!(plan_data)}
      PLAN_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      assert {:ok, plan} = result
      assert plan.status == "awaiting_review"
      assert plan.raw_plan == plan_data
      assert plan.plan_file_path == Path.join(workspace, "plan.json")

      # Verify subtasks were created (excluding planning subtask)
      plan = Plans.get_plan!(plan.id)
      real_subtasks = Enum.reject(plan.subtasks, &(&1.title == "Planning"))
      assert length(real_subtasks) == 2

      first = Enum.find(real_subtasks, &(&1.position == 1))
      assert first.title == "Create schema"
      assert first.agent_type == "claude_code"

      second = Enum.find(real_subtasks, &(&1.position == 2))
      assert second.title == "Add tests"
      assert second.agent_type == "codex"

      # Verify task transitioned to plan_review
      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "plan_review"
    end

    test "fails when agent exits with non-zero code", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "fail_script.sh")
      File.write!(script_path, "#!/bin/bash\nexit 1\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      assert {:error, {:agent_failed, 1}} = result

      # Verify task transitioned to failed
      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"
    end

    test "fails when agent writes no plan.json", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "no_plan_script.sh")
      File.write!(script_path, "#!/bin/bash\necho 'did nothing'\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      assert {:error, {:file_not_found, _}} = result

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"
    end

    test "fails when agent writes invalid plan.json", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "bad_plan_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo '{"tasks": []}' > #{Path.join(workspace, "plan.json")}
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      assert {:error, :empty_tasks} = result

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"
    end

    test "fails when agent times out", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "slow_script.sh")
      File.write!(script_path, "#!/bin/bash\nsleep 30\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 500,
          supervisor: supervisor
        )

      assert {:error, :agent_timeout} = result

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"
    end

    test "cleans up planning subtasks on agent failure", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "fail_script.sh")
      File.write!(script_path, "#!/bin/bash\nexit 1\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      {:error, {:agent_failed, 1}} =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      # Planning subtask should have been cleaned up
      plan = Plans.get_plan_by_task_id(task.id)

      if plan do
        planning_subtasks =
          plan
          |> SymphonyV2.Repo.preload(:subtasks)
          |> Map.get(:subtasks, [])
          |> Enum.filter(&(&1.title == "Planning"))

        assert planning_subtasks == [],
               "Planning subtasks should be cleaned up on error"
      end
    end

    test "cleans up planning subtasks on parse failure", %{task: task, workspace: workspace} do
      # Agent succeeds but writes empty tasks (parse will reject)
      script_path = Path.join(workspace, "empty_plan_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo '{"tasks": []}' > #{Path.join(workspace, "plan.json")}
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      {:error, :empty_tasks} =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      # Planning subtask should have been cleaned up
      plan = Plans.get_plan_by_task_id(task.id)

      if plan do
        planning_subtasks =
          plan
          |> SymphonyV2.Repo.preload(:subtasks)
          |> Map.get(:subtasks, [])
          |> Enum.filter(&(&1.title == "Planning"))

        assert planning_subtasks == [],
               "Planning subtasks should be cleaned up on parse failure"
      end
    end

    test "handles malformed JSON in plan.json", %{task: task, workspace: workspace} do
      script_path = Path.join(workspace, "malformed_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo 'not json at all {{{' > #{Path.join(workspace, "plan.json")}
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        PlanningAgent.run(task, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor
        )

      assert {:error, :invalid_json} = result

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == "failed"
    end
  end
end
