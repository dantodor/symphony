defmodule SymphonyV2.TestRunnerTest do
  use SymphonyV2.DataCase, async: false

  alias SymphonyV2.Plans
  alias SymphonyV2.TestRunner
  alias SymphonyV2.TestRunner.TestResult

  import SymphonyV2.PlansFixtures

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "symphony_test_runner_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  describe "run/3" do
    test "returns passed result for successful test command", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "true")

      assert %TestResult{} = result
      assert result.passed == true
      assert result.exit_code == 0
      assert result.duration_ms >= 0
    end

    test "returns failed result for failing test command", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "false")

      assert result.passed == false
      assert result.exit_code != 0
      assert result.duration_ms >= 0
    end

    test "captures stdout output", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "echo 'hello from tests'")

      assert result.passed == true
      assert result.output =~ "hello from tests"
    end

    test "captures stderr output (merged with stdout)", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "echo 'stderr msg' >&2")

      assert result.output =~ "stderr msg"
    end

    test "captures multi-line output", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "echo 'line1'; echo 'line2'; echo 'line3'")

      assert result.output =~ "line1"
      assert result.output =~ "line2"
      assert result.output =~ "line3"
    end

    test "runs command in the workspace directory", %{workspace: workspace} do
      File.write!(Path.join(workspace, "test_file.txt"), "workspace content")

      {:ok, result} = TestRunner.run(workspace, "cat test_file.txt")

      assert result.passed == true
      assert result.output =~ "workspace content"
    end

    test "returns error for non-existent workspace" do
      assert {:error, :workspace_not_found} = TestRunner.run("/nonexistent/path", "true")
    end

    test "handles command with non-zero exit code", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "exit 42")

      assert result.passed == false
      assert result.exit_code == 42
    end

    test "measures duration", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "sleep 0.1")

      assert result.duration_ms >= 50
    end
  end

  describe "timeout handling" do
    test "kills process on timeout and returns timeout result", %{workspace: workspace} do
      {:ok, result} = TestRunner.run(workspace, "sleep 60", timeout_ms: 500)

      assert result.passed == false
      assert result.exit_code == 137
      assert result.output =~ "TEST TIMEOUT"
      assert result.duration_ms >= 400
    end

    test "captures partial output before timeout", %{workspace: workspace} do
      script = "echo 'before timeout'; sleep 60"
      {:ok, result} = TestRunner.run(workspace, script, timeout_ms: 1000)

      assert result.passed == false
      assert result.output =~ "before timeout"
      assert result.output =~ "TEST TIMEOUT"
    end
  end

  describe "run_and_persist/4" do
    setup %{workspace: workspace} do
      subtask = subtask_fixture()
      %{subtask: subtask, workspace: workspace}
    end

    test "persists passing test result to subtask", %{workspace: workspace, subtask: subtask} do
      {:ok, result} = TestRunner.run_and_persist(workspace, "echo 'all tests pass'", subtask)

      assert result.passed == true

      # Verify DB persistence
      updated = Repo.get!(Plans.Subtask, subtask.id)
      assert updated.test_passed == true
      assert updated.test_output =~ "all tests pass"
    end

    test "persists failing test result to subtask", %{workspace: workspace, subtask: subtask} do
      {:ok, result} =
        TestRunner.run_and_persist(workspace, "echo 'test failed'; exit 1", subtask)

      assert result.passed == false

      updated = Repo.get!(Plans.Subtask, subtask.id)
      assert updated.test_passed == false
      assert updated.test_output =~ "test failed"
    end

    test "writes log file to workspace", %{workspace: workspace, subtask: subtask} do
      {:ok, _result} = TestRunner.run_and_persist(workspace, "echo 'log content'", subtask)

      log_path = Path.join([workspace, ".symphony", "logs", "test_output.log"])
      assert File.exists?(log_path)
      assert File.read!(log_path) =~ "log content"
    end

    test "returns error for non-existent workspace", %{subtask: subtask} do
      assert {:error, :workspace_not_found} =
               TestRunner.run_and_persist("/nonexistent/path", "true", subtask)
    end
  end

  describe "TestResult struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(TestResult, [])
      end
    end

    test "creates valid struct" do
      result = %TestResult{passed: true, exit_code: 0, output: "ok", duration_ms: 100}

      assert result.passed == true
      assert result.exit_code == 0
      assert result.output == "ok"
      assert result.duration_ms == 100
    end
  end
end
