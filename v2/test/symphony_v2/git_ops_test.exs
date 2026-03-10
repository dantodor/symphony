defmodule SymphonyV2.GitOpsTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.GitOps
  import SymphonyV2.GitTestHelper

  @moduletag :tmp_dir

  # ---------------------------------------------------------------------------
  # Branch naming (Step 83)
  # ---------------------------------------------------------------------------

  describe "branch_name/3" do
    test "generates correct branch name" do
      assert GitOps.branch_name("abc-123", 1, "Design auth schema") ==
               "symphony/abc-123/step-1-design-auth-schema"
    end

    test "handles position numbers" do
      assert GitOps.branch_name("task-1", 42, "Fix bug") ==
               "symphony/task-1/step-42-fix-bug"
    end
  end

  describe "slugify/1" do
    test "lowercases and hyphenates" do
      assert GitOps.slugify("Design Auth Schema") == "design-auth-schema"
    end

    test "removes special characters" do
      assert GitOps.slugify("Fix bug (critical!) #123") == "fix-bug-critical-123"
    end

    test "collapses multiple hyphens" do
      assert GitOps.slugify("hello --- world") == "hello-world"
    end

    test "trims leading and trailing hyphens" do
      assert GitOps.slugify("--hello world--") == "hello-world"
    end

    test "truncates long titles" do
      long_title = String.duplicate("word ", 20)
      slug = GitOps.slugify(long_title)
      assert String.length(slug) <= 50
    end

    test "does not end with a hyphen after truncation" do
      # Create a title that will be cut mid-word
      title = String.duplicate("abcdef ", 10)
      slug = GitOps.slugify(title)
      refute String.ends_with?(slug, "-")
    end

    test "handles empty string" do
      assert GitOps.slugify("") == ""
    end

    test "handles unicode" do
      assert GitOps.slugify("café résumé") == "caf-rsum"
    end
  end

  # ---------------------------------------------------------------------------
  # Basic git operations (Step 85)
  # ---------------------------------------------------------------------------

  describe "current_branch/1" do
    test "returns main for fresh repo", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert {:ok, "main"} = GitOps.current_branch(repo)
    end

    test "returns branch name after checkout", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature-branch")
      assert {:ok, "feature-branch"} = GitOps.current_branch(repo)
    end

    test "errors for non-existent directory" do
      assert {:error, _} = GitOps.current_branch("/nonexistent/path")
    end
  end

  describe "checkout_main/1" do
    test "switches back to main", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      assert {:ok, "feature"} = GitOps.current_branch(repo)

      :ok = GitOps.checkout_main(repo)
      assert {:ok, "main"} = GitOps.current_branch(repo)
    end

    test "errors for non-existent directory" do
      assert {:error, _} = GitOps.checkout_main("/nonexistent/path")
    end
  end

  describe "create_branch/2" do
    test "creates and switches to new branch", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "new-branch")
      assert {:ok, "new-branch"} = GitOps.current_branch(repo)
    end

    test "errors if branch already exists", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "existing")
      :ok = GitOps.checkout_main(repo)
      assert {:error, _} = GitOps.create_branch(repo, "existing")
    end
  end

  # ---------------------------------------------------------------------------
  # Change detection (Step 85)
  # ---------------------------------------------------------------------------

  describe "has_changes?/1" do
    test "returns false for clean repo", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      refute GitOps.has_changes?(repo)
    end

    test "returns true with modified file", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "README.md"), "modified")
      assert GitOps.has_changes?(repo)
    end

    test "returns true with new file", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "new.txt"), "new file")
      assert GitOps.has_changes?(repo)
    end

    test "returns true with deleted file", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.rm!(Path.join(repo, "README.md"))
      assert GitOps.has_changes?(repo)
    end
  end

  describe "changed_files/1" do
    test "returns empty list for clean repo", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert {:ok, []} = GitOps.changed_files(repo)
    end

    test "lists modified files", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "README.md"), "modified")
      File.write!(Path.join(repo, "new.txt"), "new file")

      {:ok, files} = GitOps.changed_files(repo)
      assert "README.md" in files
      assert "new.txt" in files
    end

    test "errors for non-existent directory" do
      assert {:error, _} = GitOps.changed_files("/nonexistent/path")
    end
  end

  # ---------------------------------------------------------------------------
  # Commit operations (Step 85)
  # ---------------------------------------------------------------------------

  describe "stage_and_commit/2" do
    test "commits changes and returns sha", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "new.txt"), "content")

      assert {:ok, sha} = GitOps.stage_and_commit(repo, "Add new file")
      assert String.length(sha) == 40
      refute GitOps.has_changes?(repo)
    end

    test "returns error when nothing to commit", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert {:error, :nothing_to_commit} = GitOps.stage_and_commit(repo, "Empty commit")
    end

    test "commits multiple files", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "a.txt"), "a")
      File.write!(Path.join(repo, "b.txt"), "b")
      File.write!(Path.join(repo, "c.txt"), "c")

      assert {:ok, _sha} = GitOps.stage_and_commit(repo, "Add multiple files")
      refute GitOps.has_changes?(repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Push operations (Step 85)
  # ---------------------------------------------------------------------------

  describe "push/2" do
    test "pushes branch to remote", %{tmp_dir: tmp_dir} do
      {:ok, repo, _remote} = init_temp_repo_with_remote(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      File.write!(Path.join(repo, "new.txt"), "content")
      {:ok, _sha} = GitOps.stage_and_commit(repo, "Add file")

      assert :ok = GitOps.push(repo, "feature")
    end

    test "errors when no remote", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      File.write!(Path.join(repo, "new.txt"), "content")
      {:ok, _sha} = GitOps.stage_and_commit(repo, "Add file")

      assert {:error, _} = GitOps.push(repo, "feature")
    end
  end

  describe "force_push/2" do
    test "force pushes branch to remote", %{tmp_dir: tmp_dir} do
      {:ok, repo, _remote} = init_temp_repo_with_remote(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      File.write!(Path.join(repo, "new.txt"), "content")
      {:ok, _sha} = GitOps.stage_and_commit(repo, "Add file")
      :ok = GitOps.push(repo, "feature")

      # Amend the commit and force push
      File.write!(Path.join(repo, "new.txt"), "updated content")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "--amend", "-m", "Updated file"])

      assert :ok = GitOps.force_push(repo, "feature")
    end

    test "errors when no remote", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      File.write!(Path.join(repo, "new.txt"), "content")
      {:ok, _sha} = GitOps.stage_and_commit(repo, "Add file")

      assert {:error, _} = GitOps.force_push(repo, "feature")
    end
  end

  describe "checkout/2" do
    test "switches to existing branch", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      :ok = GitOps.checkout_main(repo)

      :ok = GitOps.checkout(repo, "feature")
      assert {:ok, "feature"} = GitOps.current_branch(repo)
    end

    test "errors for non-existent branch", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert {:error, _} = GitOps.checkout(repo, "nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # Stacked branch workflow (Step 86)
  # ---------------------------------------------------------------------------

  describe "create_stacked_branch/3" do
    test "creates branch from specified base", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Create first branch with a commit
      :ok = GitOps.create_branch(repo, "step-1")
      write_and_commit(repo, "step1.txt", "step 1", "Step 1 work")

      # Create second branch stacked on first
      :ok = GitOps.create_stacked_branch(repo, "step-1", "step-2")
      assert {:ok, "step-2"} = GitOps.current_branch(repo)

      # step-2 should have step1.txt from the base branch
      assert File.exists?(Path.join(repo, "step1.txt"))
    end

    test "errors if base branch does not exist", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert {:error, _} = GitOps.create_stacked_branch(repo, "nonexistent", "new-branch")
    end
  end

  describe "stacked branch workflow" do
    test "creates a stack of 3 branches with incremental work", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Step 1: branch from main
      :ok = GitOps.create_branch(repo, "symphony/t1/step-1-auth")
      write_and_commit(repo, "auth.ex", "defmodule Auth", "Add auth module")

      # Step 2: branch from step 1
      :ok =
        GitOps.create_stacked_branch(repo, "symphony/t1/step-1-auth", "symphony/t1/step-2-api")

      assert File.exists?(Path.join(repo, "auth.ex"))
      write_and_commit(repo, "api.ex", "defmodule Api", "Add API module")

      # Step 3: branch from step 2
      :ok =
        GitOps.create_stacked_branch(repo, "symphony/t1/step-2-api", "symphony/t1/step-3-tests")

      assert File.exists?(Path.join(repo, "auth.ex"))
      assert File.exists?(Path.join(repo, "api.ex"))
      write_and_commit(repo, "test.exs", "defmodule Test", "Add tests")

      # Verify each branch has correct files
      :ok = GitOps.checkout(repo, "symphony/t1/step-1-auth")
      assert File.exists?(Path.join(repo, "auth.ex"))
      refute File.exists?(Path.join(repo, "api.ex"))
      refute File.exists?(Path.join(repo, "test.exs"))

      :ok = GitOps.checkout(repo, "symphony/t1/step-2-api")
      assert File.exists?(Path.join(repo, "auth.ex"))
      assert File.exists?(Path.join(repo, "api.ex"))
      refute File.exists?(Path.join(repo, "test.exs"))

      :ok = GitOps.checkout(repo, "symphony/t1/step-3-tests")
      assert File.exists?(Path.join(repo, "auth.ex"))
      assert File.exists?(Path.join(repo, "api.ex"))
      assert File.exists?(Path.join(repo, "test.exs"))
    end
  end

  # ---------------------------------------------------------------------------
  # Rebase operations (Step 86)
  # ---------------------------------------------------------------------------

  describe "rebase_onto/2" do
    test "rebases current branch onto target", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Create feature branch
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "feature.txt", "feature work", "Feature commit")

      # Add work to main
      :ok = GitOps.checkout_main(repo)
      write_and_commit(repo, "main-work.txt", "main work", "Main commit")

      # Rebase feature onto main
      :ok = GitOps.checkout(repo, "feature")
      assert :ok = GitOps.rebase_onto(repo, "main")

      # feature should have both files
      assert File.exists?(Path.join(repo, "feature.txt"))
      assert File.exists?(Path.join(repo, "main-work.txt"))
    end

    test "returns conflict error on conflicting changes", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Create feature branch that modifies README
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "README.md", "feature version", "Feature change")

      # Modify same file on main
      :ok = GitOps.checkout_main(repo)
      write_and_commit(repo, "README.md", "main version", "Main change")

      # Rebase should conflict
      :ok = GitOps.checkout(repo, "feature")
      assert {:error, :conflict} = GitOps.rebase_onto(repo, "main")

      # Workspace should be clean (rebase aborted)
      assert {:ok, "feature"} = GitOps.current_branch(repo)
    end
  end

  describe "rebase_stack_onto_main/2" do
    test "rebases a stack of branches onto main", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Build a stack
      :ok = GitOps.create_branch(repo, "step-1")
      write_and_commit(repo, "step1.txt", "step 1", "Step 1")

      :ok = GitOps.create_stacked_branch(repo, "step-1", "step-2")
      write_and_commit(repo, "step2.txt", "step 2", "Step 2")

      :ok = GitOps.create_stacked_branch(repo, "step-2", "step-3")
      write_and_commit(repo, "step3.txt", "step 3", "Step 3")

      # Advance main
      :ok = GitOps.checkout_main(repo)
      write_and_commit(repo, "main-new.txt", "main progress", "Main progress")

      # Rebase the stack
      branches = ["step-1", "step-2", "step-3"]
      assert :ok = GitOps.rebase_stack_onto_main(repo, branches)

      # Each branch should have main's new work
      for branch <- branches do
        :ok = GitOps.checkout(repo, branch)

        assert File.exists?(Path.join(repo, "main-new.txt")),
               "#{branch} should have main-new.txt"
      end

      # Step-3 should have all files
      :ok = GitOps.checkout(repo, "step-3")
      assert File.exists?(Path.join(repo, "step1.txt"))
      assert File.exists?(Path.join(repo, "step2.txt"))
      assert File.exists?(Path.join(repo, "step3.txt"))
      assert File.exists?(Path.join(repo, "main-new.txt"))
    end

    test "returns conflict info when rebase fails", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)

      # Build a stack where step-1 modifies README
      :ok = GitOps.create_branch(repo, "step-1")
      write_and_commit(repo, "README.md", "step 1 version", "Step 1 changes README")

      :ok = GitOps.create_stacked_branch(repo, "step-1", "step-2")
      write_and_commit(repo, "step2.txt", "step 2", "Step 2")

      # Advance main with conflicting change
      :ok = GitOps.checkout_main(repo)
      write_and_commit(repo, "README.md", "main version", "Main changes README")

      # Rebase should fail at step-1
      assert {:error, {:conflict, "step-1"}} =
               GitOps.rebase_stack_onto_main(repo, ["step-1", "step-2"])
    end

    test "handles empty branch list", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      assert :ok = GitOps.rebase_stack_onto_main(repo, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Diff operations
  # ---------------------------------------------------------------------------

  describe "diff/3" do
    test "returns diff output between refs", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "new.txt", "hello world", "Add file")

      {:ok, output} = GitOps.diff(repo, "main", "feature")
      assert String.contains?(output, "hello world")
      assert String.contains?(output, "new.txt")
    end

    test "returns empty diff for identical refs", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      {:ok, output} = GitOps.diff(repo, "main", "main")
      assert output == ""
    end
  end

  describe "diff_stat/3" do
    test "returns stat output between refs", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "new.txt", "hello", "Add file")

      {:ok, output} = GitOps.diff_stat(repo, "main", "feature")
      assert String.contains?(output, "new.txt")
      assert String.contains?(output, "1 file changed")
    end
  end

  describe "diff_name_only/3" do
    test "lists changed files between refs", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "new.txt", "content", "Add file")

      {:ok, files} = GitOps.diff_name_only(repo, "main", "feature")
      assert files == ["new.txt"]
    end

    test "lists multiple changed files", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      :ok = GitOps.create_branch(repo, "feature")
      write_and_commit(repo, "a.txt", "a", "Add a")
      write_and_commit(repo, "b.txt", "b", "Add b")

      {:ok, files} = GitOps.diff_name_only(repo, "main", "feature")
      assert Enum.sort(files) == ["a.txt", "b.txt"]
    end
  end

  # ---------------------------------------------------------------------------
  # Reset operations
  # ---------------------------------------------------------------------------

  describe "reset_hard/1" do
    test "discards uncommitted changes", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "README.md"), "modified")
      assert GitOps.has_changes?(repo)

      :ok = GitOps.reset_hard(repo)
      refute GitOps.has_changes?(repo)
    end

    test "discards staged changes", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "README.md"), "modified")
      git!(repo, ["add", "-A"])

      :ok = GitOps.reset_hard(repo)
      refute GitOps.has_changes?(repo)
    end
  end

  describe "clean/1" do
    test "removes untracked files", %{tmp_dir: tmp_dir} do
      {:ok, repo} = init_temp_repo(tmp_dir)
      File.write!(Path.join(repo, "untracked.txt"), "junk")
      assert File.exists?(Path.join(repo, "untracked.txt"))

      :ok = GitOps.clean(repo)
      refute File.exists?(Path.join(repo, "untracked.txt"))
    end
  end
end
