defmodule SymphonyV2.WorkspaceTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Workspace

  @moduletag :tmp_dir

  describe "create/2" do
    test "creates workspace directory for a task", %{tmp_dir: tmp_dir} do
      task_id = "abc-123"

      assert {:ok, path} = Workspace.create(tmp_dir, task_id)
      assert path == Path.join(tmp_dir, "task-abc-123")
      assert File.dir?(path)
    end

    test "returns ok if workspace already exists", %{tmp_dir: tmp_dir} do
      task_id = "existing-task"
      expected_path = Path.join(tmp_dir, "task-#{task_id}")
      File.mkdir_p!(expected_path)

      assert {:ok, ^expected_path} = Workspace.create(tmp_dir, task_id)
    end

    test "rejects path traversal in task_id", %{tmp_dir: tmp_dir} do
      # task-../../../../etc expands to a path outside tmp_dir
      assert {:error, {:path_outside_root, _, _}} =
               Workspace.create(tmp_dir, "../../../../etc")
    end
  end

  describe "clone_repo/2" do
    test "clones a git repo into workspace", %{tmp_dir: tmp_dir} do
      # Create a source repo with an initial commit
      repo_path = Path.join(tmp_dir, "source-repo")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)
      File.write!(Path.join(repo_path, "README.md"), "# Test")
      System.cmd("git", ["add", "."], cd: repo_path)
      System.cmd("git", ["commit", "-m", "init"], cd: repo_path, stderr_to_stdout: true)

      workspace = Path.join(tmp_dir, "clone-target")

      assert {:ok, ^workspace} = Workspace.clone_repo(repo_path, workspace)
      assert File.dir?(Path.join(workspace, ".git"))
      assert File.exists?(Path.join(workspace, "README.md"))
    end

    test "returns error for invalid repo path", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "bad-clone")

      assert {:error, {:clone_failed, _, _}} =
               Workspace.clone_repo("/nonexistent/repo", workspace)
    end
  end

  describe "validate_path/2" do
    test "accepts valid path under root", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "task-123")
      assert :ok = Workspace.validate_path(path, tmp_dir)
    end

    test "accepts nested path under root", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "task-123", "subdir"])
      assert :ok = Workspace.validate_path(path, tmp_dir)
    end

    test "rejects path equal to root", %{tmp_dir: tmp_dir} do
      assert {:error, {:path_equals_root, _}} = Workspace.validate_path(tmp_dir, tmp_dir)
    end

    test "rejects path outside root", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "../outside")
      assert {:error, {:path_outside_root, _, _}} = Workspace.validate_path(outside, tmp_dir)
    end

    test "rejects path traversal via ..", %{tmp_dir: tmp_dir} do
      traversal = Path.join([tmp_dir, "task-123", "..", "..", "etc"])
      assert {:error, {:path_outside_root, _, _}} = Workspace.validate_path(traversal, tmp_dir)
    end

    test "rejects symlink that escapes root", %{tmp_dir: tmp_dir} do
      # Create a directory outside root
      outside_dir = Path.join(tmp_dir, "outside")
      File.mkdir_p!(outside_dir)

      # Create workspace root inside tmp_dir
      root = Path.join(tmp_dir, "workspaces")
      File.mkdir_p!(root)

      # Create a symlink inside root that points outside
      symlink_path = Path.join(root, "evil-link")
      File.ln_s!(outside_dir, symlink_path)

      target = Path.join(symlink_path, "payload")
      assert {:error, {:symlink_in_path, ^symlink_path}} = Workspace.validate_path(target, root)
    end

    test "accepts path with spaces", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "task with spaces")
      assert :ok = Workspace.validate_path(path, tmp_dir)
    end

    test "returns error for unreadable path component", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "ws_root")
      File.mkdir_p!(root)
      restricted = Path.join(root, "restricted")
      File.mkdir_p!(restricted)
      File.chmod!(restricted, 0o000)

      target = Path.join(restricted, "task-1")
      result = Workspace.validate_path(target, root)

      # Restore permissions for cleanup
      File.chmod!(restricted, 0o755)

      assert {:error, {:path_unreadable, _, _}} = result
    end
  end

  describe "cleanup/2" do
    test "removes workspace directory", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "task-cleanup")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "file.txt"), "data")

      assert {:ok, _paths} = Workspace.cleanup(path, tmp_dir)
      refute File.exists?(path)
    end

    test "rejects cleanup of path outside root", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "../outside-cleanup")
      assert {:error, {:path_outside_root, _, _}} = Workspace.cleanup(outside, tmp_dir)
    end

    test "succeeds even if path doesn't exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "task-nonexistent")
      assert {:ok, _} = Workspace.cleanup(path, tmp_dir)
    end
  end

  describe "exists?/2" do
    test "returns true when workspace exists", %{tmp_dir: tmp_dir} do
      task_id = "exists-task"
      File.mkdir_p!(Path.join(tmp_dir, "task-#{task_id}"))

      assert Workspace.exists?(tmp_dir, task_id)
    end

    test "returns false when workspace doesn't exist", %{tmp_dir: tmp_dir} do
      refute Workspace.exists?(tmp_dir, "no-such-task")
    end
  end

  describe "workspace_path/2" do
    test "builds correct path" do
      assert Workspace.workspace_path("/tmp/workspaces", "abc-123") ==
               "/tmp/workspaces/task-abc-123"
    end
  end

  describe "full lifecycle integration" do
    test "create → clone → verify → cleanup", %{tmp_dir: tmp_dir} do
      # Set up a source repo
      repo_path = Path.join(tmp_dir, "source")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)
      File.write!(Path.join(repo_path, "mix.exs"), "defmodule App.MixProject do end")
      System.cmd("git", ["add", "."], cd: repo_path)
      System.cmd("git", ["commit", "-m", "initial commit"], cd: repo_path, stderr_to_stdout: true)

      workspace_root = Path.join(tmp_dir, "workspaces")
      File.mkdir_p!(workspace_root)
      task_id = "lifecycle-test"

      # Step 1: Create workspace
      assert {:ok, workspace} = Workspace.create(workspace_root, task_id)
      assert File.dir?(workspace)

      # Step 2: Clone repo into workspace — need to remove the empty dir first
      # since git clone wants the target to not exist or be empty
      File.rm_rf!(workspace)
      assert {:ok, _} = Workspace.clone_repo(repo_path, workspace)

      # Step 3: Verify git repo initialized
      assert File.dir?(Path.join(workspace, ".git"))
      assert File.exists?(Path.join(workspace, "mix.exs"))

      # Verify exists?
      assert Workspace.exists?(workspace_root, task_id)

      # Step 4: Cleanup
      assert {:ok, _} = Workspace.cleanup(workspace, workspace_root)

      # Step 5: Verify removed
      refute File.exists?(workspace)
      refute Workspace.exists?(workspace_root, task_id)
    end
  end
end
