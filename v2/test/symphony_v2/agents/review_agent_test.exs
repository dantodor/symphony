defmodule SymphonyV2.Agents.ReviewAgentTest do
  use SymphonyV2.DataCase

  alias SymphonyV2.Agents.ReviewAgent
  alias SymphonyV2.Plans
  alias SymphonyV2.Tasks
  alias SymphonyV2.TasksFixtures

  @sample_diff """
  diff --git a/lib/example.ex b/lib/example.ex
  new file mode 100644
  --- /dev/null
  +++ b/lib/example.ex
  @@ -0,0 +1,5 @@
  +defmodule Example do
  +  def hello do
  +    :world
  +  end
  +end
  """

  setup do
    task = TasksFixtures.task_fixture()
    {:ok, task} = Tasks.update_task_status(task, "planning")

    workspace =
      Path.join(System.tmp_dir!(), "review_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    # Create plan and subtask for testing
    {:ok, plan} = Plans.create_plan(%{task_id: task.id, status: "executing"})

    {:ok, [subtask]} =
      Plans.create_subtasks_from_plan(plan, [
        %{
          position: 1,
          title: "Implement feature",
          spec: "Create a module with a hello function that returns :world",
          agent_type: "claude_code"
        }
      ])

    # Transition subtask through valid state machine to in_review
    {:ok, subtask} = Plans.update_subtask_status(subtask, "dispatched")
    {:ok, subtask} = Plans.update_subtask_status(subtask, "running")
    {:ok, subtask} = Plans.update_subtask_status(subtask, "testing")
    {:ok, subtask} = Plans.update_subtask_status(subtask, "in_review")

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{task: task, plan: plan, subtask: subtask, workspace: workspace}
  end

  describe "build_prompt/2" do
    test "includes subtask title and spec", %{subtask: subtask} do
      prompt = ReviewAgent.build_prompt(subtask, @sample_diff)

      assert prompt =~ subtask.title
      assert prompt =~ subtask.spec
    end

    test "includes the diff", %{subtask: subtask} do
      prompt = ReviewAgent.build_prompt(subtask, @sample_diff)

      assert prompt =~ "defmodule Example do"
      assert prompt =~ "+  def hello do"
    end

    test "includes review instructions", %{subtask: subtask} do
      prompt = ReviewAgent.build_prompt(subtask, @sample_diff)

      assert prompt =~ "Corner-cutting"
      assert prompt =~ "Meaningless tests"
      assert prompt =~ "Hardcoded values"
      assert prompt =~ "Skipped requirements"
    end

    test "includes review.json format", %{subtask: subtask} do
      prompt = ReviewAgent.build_prompt(subtask, @sample_diff)

      assert prompt =~ "review.json"
      assert prompt =~ "verdict"
      assert prompt =~ "approved"
      assert prompt =~ "rejected"
      assert prompt =~ "reasoning"
      assert prompt =~ "issues"
    end
  end

  describe "review_file_path/1" do
    test "returns correct path" do
      assert ReviewAgent.review_file_path("/workspace") == "/workspace/review.json"
    end
  end

  describe "run/3 with mock agent" do
    test "succeeds with approved review", %{subtask: subtask, workspace: workspace} do
      review_data = %{
        "verdict" => "approved",
        "reasoning" => "The implementation correctly satisfies the specification.",
        "issues" => []
      }

      script_path = Path.join(workspace, "review_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:ok, review} = result
      assert review.verdict == "approved"
      assert review.reasoning == "The implementation correctly satisfies the specification."

      # Verify subtask was updated
      updated = Plans.get_plan!(subtask.execution_plan_id)
      updated_subtask = hd(updated.subtasks)
      assert updated_subtask.review_verdict == "approved"
      assert updated_subtask.status == "succeeded"
    end

    test "returns rejected review and updates subtask", %{
      subtask: subtask,
      workspace: workspace
    } do
      review_data = %{
        "verdict" => "rejected",
        "reasoning" => "Tests use hardcoded values to pass assertions.",
        "issues" => [
          %{"severity" => "critical", "description" => "Test assertions are hardcoded"}
        ]
      }

      script_path = Path.join(workspace, "review_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:ok, review} = result
      assert review.verdict == "rejected"

      # Verify subtask was updated with rejection info
      updated = Plans.get_plan!(subtask.execution_plan_id)
      updated_subtask = hd(updated.subtasks)
      assert updated_subtask.review_verdict == "rejected"
      assert updated_subtask.review_reasoning =~ "hardcoded"
      assert updated_subtask.last_error =~ "hardcoded"
      # Status should NOT be changed to succeeded for rejections
      refute updated_subtask.status == "succeeded"
    end

    test "fails when agent exits with non-zero code", %{
      subtask: subtask,
      workspace: workspace
    } do
      script_path = Path.join(workspace, "fail_script.sh")
      File.write!(script_path, "#!/bin/bash\nexit 1\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, {:agent_failed, 1}} = result
    end

    test "fails when agent writes no review.json", %{subtask: subtask, workspace: workspace} do
      script_path = Path.join(workspace, "no_review_script.sh")
      File.write!(script_path, "#!/bin/bash\necho 'did nothing'\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, {:file_not_found, _}} = result
    end

    test "fails when agent times out", %{subtask: subtask, workspace: workspace} do
      script_path = Path.join(workspace, "slow_script.sh")
      File.write!(script_path, "#!/bin/bash\nsleep 30\n")
      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 500,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, :agent_timeout} = result
    end

    test "fails when review.json has invalid format", %{subtask: subtask, workspace: workspace} do
      script_path = Path.join(workspace, "bad_review_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo 'not json {{{' > #{Path.join(workspace, "review.json")}
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, :invalid_json} = result
    end

    test "fails when review agent is same type as executor", %{
      subtask: subtask,
      workspace: workspace
    } do
      # subtask.agent_type is "claude_code", so using :claude_code should fail
      result =
        ReviewAgent.run(subtask, workspace,
          diff: @sample_diff,
          agent_type: :claude_code
        )

      assert {:error, {:same_agent_type, "claude_code"}} = result
    end

    test "fails when review.json has missing verdict", %{subtask: subtask, workspace: workspace} do
      review_data = %{"reasoning" => "Some reasoning but no verdict"}

      script_path = Path.join(workspace, "no_verdict_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, :missing_verdict} = result

      # Verify last_error was set on subtask
      updated = Plans.get_plan!(subtask.execution_plan_id)
      updated_subtask = hd(updated.subtasks)
      assert updated_subtask.last_error =~ "missing 'verdict'"
    end

    test "fails when review.json is a non-map JSON value", %{
      subtask: subtask,
      workspace: workspace
    } do
      script_path = Path.join(workspace, "array_review_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      echo '[1, 2, 3]' > #{Path.join(workspace, "review.json")}
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, :invalid_review_format} = result
    end

    test "fails when review.json has invalid verdict value", %{
      subtask: subtask,
      workspace: workspace
    } do
      review_data = %{"verdict" => "maybe", "reasoning" => "Not sure about this."}

      script_path = Path.join(workspace, "bad_verdict_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, {:invalid_verdict, "maybe"}} = result
    end

    test "fails when review.json has empty reasoning", %{
      subtask: subtask,
      workspace: workspace
    } do
      review_data = %{"verdict" => "approved", "reasoning" => "   "}

      script_path = Path.join(workspace, "empty_reasoning_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, :empty_reasoning} = result
    end

    test "fails when review.json has invalid issues", %{
      subtask: subtask,
      workspace: workspace
    } do
      review_data = %{
        "verdict" => "rejected",
        "reasoning" => "Problems found.",
        "issues" => [%{"severity" => "blocker", "description" => "Something"}]
      }

      script_path = Path.join(workspace, "bad_issues_script.sh")

      File.write!(script_path, """
      #!/bin/bash
      cat > #{Path.join(workspace, "review.json")} << 'REVIEW_EOF'
      #{Jason.encode!(review_data)}
      REVIEW_EOF
      """)

      File.chmod!(script_path, 0o755)

      {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

      result =
        ReviewAgent.run(subtask, workspace,
          safehouse_opts: [command_override: {script_path, []}],
          timeout_ms: 10_000,
          supervisor: supervisor,
          diff: @sample_diff,
          agent_type: :codex
        )

      assert {:error, {:invalid_issues, _}} = result
    end
  end

  describe "compute_diff via git" do
    setup %{plan: plan} do
      # Create a subtask with a branch_name set (simulating post-agent state)
      {:ok, [subtask]} =
        Plans.create_subtasks_from_plan(plan, [
          %{
            position: 2,
            title: "Second feature",
            spec: "Add another feature",
            agent_type: "claude_code"
          }
        ])

      {:ok, subtask} = Plans.update_subtask_status(subtask, "dispatched")
      {:ok, subtask} = Plans.update_subtask_status(subtask, "running")
      {:ok, subtask} = Plans.update_subtask_status(subtask, "testing")
      {:ok, subtask} = Plans.update_subtask_status(subtask, "in_review")

      {:ok, subtask} =
        Plans.update_subtask(subtask, %{
          branch_name: "symphony/test-task/step-1-second-feature"
        })

      %{branched_subtask: subtask}
    end

    test "falls back to main as base branch for step-1", %{
      branched_subtask: subtask,
      workspace: workspace
    } do
      # Without a real git repo, compute_diff will fail with diff_failed
      result =
        ReviewAgent.run(subtask, workspace, agent_type: :codex)

      assert {:error, {:diff_failed, _}} = result
    end

    test "returns no_changes when diff is empty", %{
      branched_subtask: subtask,
      workspace: workspace
    } do
      # Initialize a git repo so diff returns empty string
      System.cmd("git", ["init"], cd: workspace)
      System.cmd("git", ["checkout", "-b", "main"], cd: workspace)
      File.write!(Path.join(workspace, "README.md"), "hello")
      System.cmd("git", ["add", "."], cd: workspace)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=t@t.com", "commit", "-m", "init"],
        cd: workspace
      )

      System.cmd("git", ["checkout", "-b", "symphony/test-task/step-1-second-feature"],
        cd: workspace
      )

      result =
        ReviewAgent.run(subtask, workspace, agent_type: :codex)

      assert {:error, :no_changes} = result
    end
  end
end
