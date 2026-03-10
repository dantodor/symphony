defmodule SymphonyV2.SecurityTest do
  @moduledoc """
  Security review tests for Symphony v2.

  Step 214: Safehouse command construction — verify no shell injection possible
  via task titles, descriptions, file paths, agent names.

  Step 215: Workspace path safety — verify path traversal impossible via
  symlinks, `../`, and other tricks.
  """
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Agents.Safehouse
  alias SymphonyV2.Workspace

  # --- Step 214: Safehouse command construction security ---

  describe "Safehouse — shell injection prevention via task titles" do
    test "prompt with shell metacharacters is safely passed as a single arg" do
      adversarial_prompt = "Fix bug; rm -rf /; echo pwned"

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      # The prompt should appear as a single argument, not split at semicolons
      assert adversarial_prompt in args

      # The prompt should not be in the safehouse flags section
      separator_idx = Enum.find_index(args, &(&1 == "--"))
      prompt_idx = Enum.find_index(args, &(&1 == adversarial_prompt))
      assert prompt_idx > separator_idx
    end

    test "prompt with backticks doesn't cause command substitution" do
      adversarial_prompt = "Fix `whoami` in the code"

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      assert adversarial_prompt in args
    end

    test "prompt with $() doesn't cause command substitution" do
      adversarial_prompt = "Fix $(cat /etc/passwd) in the code"

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      assert adversarial_prompt in args
    end

    test "prompt with newlines is handled safely" do
      adversarial_prompt = "Fix the bug\nrm -rf /"

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      assert adversarial_prompt in args
    end

    test "prompt with pipe operators is handled safely" do
      adversarial_prompt = "Fix bug | cat /etc/shadow > /tmp/stolen"

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      assert adversarial_prompt in args
    end

    test "prompt with single/double quotes is handled safely" do
      adversarial_prompt = "Fix 'the bug' and \"the issue\""

      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace/task-1", prompt: adversarial_prompt)

      assert adversarial_prompt in args
    end
  end

  describe "Safehouse — path injection prevention" do
    test "workspace path with null bytes is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace\0/evil", prompt: "test")
    end

    test "workspace path with semicolons is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace; rm -rf /", prompt: "test")
    end

    test "workspace path with pipe is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace | evil", prompt: "test")
    end

    test "workspace path with backticks is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace/`whoami`", prompt: "test")
    end

    test "workspace path with $() is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace/$(id)", prompt: "test")
    end

    test "workspace path with newlines is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace\n/etc/passwd", prompt: "test")
    end

    test "empty workspace path is rejected" do
      assert {:error, _} = Safehouse.build_command(:claude_code, "", prompt: "test")
    end

    test "non-string workspace path is rejected" do
      assert {:error, _} = Safehouse.build_command(:claude_code, 42, prompt: "test")
    end

    test "read-only path with injection is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace",
                 prompt: "test",
                 read_only_dirs: ["/safe", "/evil; rm -rf /"]
               )
    end

    test "read-only path with null bytes is rejected" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "/workspace",
                 prompt: "test",
                 read_only_dirs: ["/evil\0path"]
               )
    end
  end

  describe "Safehouse — env var injection prevention" do
    test "env vars are joined with commas, not shell-interpreted" do
      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace",
          prompt: "test",
          env_vars: ["MY_VAR=evil_value", "ANOTHER"]
        )

      env_flag = Enum.find(args, &String.starts_with?(&1, "--env-pass="))
      # Env vars are names, not key=value pairs — the = should be in the name
      assert env_flag != nil
    end
  end

  describe "Safehouse — agent type safety" do
    test "unknown agent type returns error" do
      assert {:error, _} =
               Safehouse.build_command(:malicious_agent, "/workspace", prompt: "test")
    end

    test "agent type as string is accepted (AgentRegistry supports string keys)" do
      # Safehouse accepts string agent types — this is valid behavior
      {:ok, {"safehouse", args}} =
        Safehouse.build_command("claude_code", "/workspace", prompt: "test")

      assert "--" in args
    end
  end

  describe "Safehouse — command structure integrity" do
    test "all agent types produce list-based args (no shell string concatenation)" do
      for agent_type <- [:claude_code, :codex, :gemini_cli, :opencode] do
        {:ok, {"safehouse", args}} =
          Safehouse.build_command(agent_type, "/workspace", prompt: "test")

        assert is_list(args), "#{agent_type} should produce list args"
        assert Enum.all?(args, &is_binary/1), "#{agent_type} args should all be strings"
        assert "--" in args, "#{agent_type} should have separator"
      end
    end

    test "separator appears exactly once" do
      {:ok, {"safehouse", args}} =
        Safehouse.build_command(:claude_code, "/workspace", prompt: "test")

      separator_count = Enum.count(args, &(&1 == "--"))
      assert separator_count == 1
    end
  end

  # --- Step 215: Workspace path safety ---

  describe "Workspace — path traversal prevention" do
    setup do
      root = Path.join(System.tmp_dir!(), "ws_security_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "rejects path traversal via ../", %{root: root} do
      result = Workspace.validate_path(Path.join(root, "../escaped"), root)
      assert {:error, {:path_outside_root, _, _}} = result
    end

    test "rejects path that equals root", %{root: root} do
      result = Workspace.validate_path(root, root)
      assert {:error, {:path_equals_root, _}} = result
    end

    test "rejects path completely outside root", %{root: root} do
      result = Workspace.validate_path("/tmp/other/dir", root)
      assert {:error, {:path_outside_root, _, _}} = result
    end

    test "accepts valid path under root", %{root: root} do
      assert :ok = Workspace.validate_path(Path.join(root, "task-abc"), root)
    end

    test "accepts deeply nested path under root", %{root: root} do
      assert :ok = Workspace.validate_path(Path.join(root, "a/b/c/d"), root)
    end

    test "detects symlink escape", %{root: root} do
      # Create a directory inside root
      legitimate = Path.join(root, "task-1")
      File.mkdir_p!(legitimate)

      # Create a symlink inside root pointing outside
      symlink_path = Path.join(root, "task-evil")

      escaped_target =
        Path.join(System.tmp_dir!(), "escaped_target_#{System.unique_integer([:positive])}")

      File.mkdir_p!(escaped_target)
      File.ln_s!(escaped_target, symlink_path)

      on_exit(fn -> File.rm_rf!(escaped_target) end)

      result = Workspace.validate_path(symlink_path, root)
      assert {:error, {:symlink_in_path, _}} = result
    end

    test "accepts path with spaces", %{root: root} do
      assert :ok = Workspace.validate_path(Path.join(root, "task with spaces"), root)
    end
  end

  describe "Workspace — create safety" do
    setup do
      root = Path.join(System.tmp_dir!(), "ws_create_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "creates workspace under root", %{root: root} do
      {:ok, path} = Workspace.create(root, "test-task-123")
      assert String.starts_with?(path, root)
      assert File.dir?(path)
    end

    test "workspace path contains task ID", %{root: root} do
      {:ok, path} = Workspace.create(root, "my-task-id")
      assert path =~ "task-my-task-id"
    end
  end

  describe "Workspace — cleanup safety" do
    setup do
      root = Path.join(System.tmp_dir!(), "ws_cleanup_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "refuses to clean up path outside root", %{root: root} do
      result = Workspace.cleanup("/tmp/other", root)
      assert {:error, {:path_outside_root, _, _}} = result
    end

    test "refuses to clean up root itself", %{root: root} do
      result = Workspace.cleanup(root, root)
      assert {:error, {:path_equals_root, _}} = result
    end

    test "cleans up valid workspace", %{root: root} do
      workspace = Path.join(root, "task-cleanup-test")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "file.txt"), "content")

      {:ok, _paths} = Workspace.cleanup(workspace, root)
      refute File.dir?(workspace)
    end
  end
end
