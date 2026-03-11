defmodule SymphonyV2.Agents.SafehouseTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Agents.Safehouse

  # All command-building tests skip safehouse binary check since it may not be installed
  @skip_check [skip_safehouse_check: true]

  describe "build_command/3" do
    test "builds correct command for claude_code" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Fix the bug"] ++ @skip_check
               )

      assert args == [
               "--add-dirs=/workspace/task-1",
               "--env-pass=ANTHROPIC_API_KEY",
               "--",
               "claude",
               "-p",
               "Fix the bug",
               "--dangerously-skip-permissions"
             ]
    end

    test "builds correct command for codex" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :codex,
                 "/workspace/task-1",
                 [prompt: "Add tests"] ++ @skip_check
               )

      assert args == [
               "--add-dirs=/workspace/task-1",
               "--env-pass=OPENAI_API_KEY",
               "--",
               "codex",
               "-q",
               "Add tests",
               "--dangerously-bypass-approvals-and-sandbox"
             ]
    end

    test "builds correct command for gemini_cli" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :gemini_cli,
                 "/workspace/task-1",
                 [prompt: "Refactor module"] ++ @skip_check
               )

      assert args == [
               "--add-dirs=/workspace/task-1",
               "--env-pass=GEMINI_API_KEY",
               "--",
               "gemini",
               "-p",
               "Refactor module"
             ]
    end

    test "builds correct command for opencode (no env vars, no skip flag)" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :opencode,
                 "/workspace/task-1",
                 [prompt: "Fix it"] ++ @skip_check
               )

      assert args == [
               "--add-dirs=/workspace/task-1",
               "--",
               "opencode",
               "-p",
               "Fix it"
             ]
    end

    test "includes read-only directories" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", read_only_dirs: ["/shared/libs", "/shared/config"]] ++
                   @skip_check
               )

      assert "--add-dirs-ro=/shared/libs" in args
      assert "--add-dirs-ro=/shared/config" in args
    end

    test "read-only dirs appear after writable dir and before separator" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", read_only_dirs: ["/shared/libs"]] ++ @skip_check
               )

      writable_idx = Enum.find_index(args, &(&1 == "--add-dirs=/workspace/task-1"))
      ro_idx = Enum.find_index(args, &(&1 == "--add-dirs-ro=/shared/libs"))
      separator_idx = Enum.find_index(args, &(&1 == "--"))

      assert writable_idx < ro_idx
      assert ro_idx < separator_idx
    end

    test "forwards extra environment variables" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", env_vars: ["GITHUB_TOKEN", "MY_VAR"]] ++ @skip_check
               )

      env_flag = Enum.find(args, &String.starts_with?(&1, "--env-pass="))
      assert env_flag == "--env-pass=ANTHROPIC_API_KEY,GITHUB_TOKEN,MY_VAR"
    end

    test "deduplicates environment variables" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", env_vars: ["ANTHROPIC_API_KEY", "EXTRA"]] ++ @skip_check
               )

      env_flag = Enum.find(args, &String.starts_with?(&1, "--env-pass="))
      assert env_flag == "--env-pass=ANTHROPIC_API_KEY,EXTRA"
    end

    test "omits skip-permissions flag when skip_permissions is false" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", skip_permissions: false] ++ @skip_check
               )

      refute "--dangerously-skip-permissions" in args
    end

    test "skip_permissions defaults to true" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it"] ++ @skip_check
               )

      assert "--dangerously-skip-permissions" in args
    end

    test "agents without skip-permissions flag don't include it regardless" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :gemini_cli,
                 "/workspace/task-1",
                 [prompt: "Do it", skip_permissions: true] ++ @skip_check
               )

      refute Enum.any?(args, &String.contains?(&1, "dangerously"))
    end

    test "returns error for unknown agent type" do
      assert {:error, msg} =
               Safehouse.build_command(
                 :nonexistent,
                 "/workspace",
                 [prompt: "Do it"] ++ @skip_check
               )

      assert msg =~ "unknown agent type"
    end

    test "raises when prompt is missing" do
      assert_raise KeyError, fn ->
        Safehouse.build_command(:claude_code, "/workspace/task-1", @skip_check)
      end
    end
  end

  describe "build_command/3 — path safety" do
    test "rejects paths with null bytes" do
      assert {:error, msg} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace\0/evil",
                 [prompt: "Do it"] ++ @skip_check
               )

      assert msg =~ "unsafe path"
    end

    test "rejects paths with semicolons" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace; rm -rf /",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects paths with pipes" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace | cat /etc/passwd",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects paths with ampersands" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace & echo pwned",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects paths with backticks" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/`whoami`",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects paths with command substitution" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/$(whoami)",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects paths with newlines" do
      assert {:error, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace\n/etc/passwd",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects empty paths" do
      assert {:error, _} =
               Safehouse.build_command(:claude_code, "", [prompt: "Do it"] ++ @skip_check)
    end

    test "rejects unsafe read-only paths" do
      assert {:error, msg} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it", read_only_dirs: ["/safe/path", "/evil; rm -rf /"]] ++
                   @skip_check
               )

      assert msg =~ "unsafe path"
    end

    test "accepts paths with spaces" do
      assert {:ok, {"safehouse", args}} =
               Safehouse.build_command(
                 :claude_code,
                 "/my workspace/task 1",
                 [prompt: "Do it"] ++ @skip_check
               )

      assert "--add-dirs=/my workspace/task 1" in args
    end

    test "accepts paths with dots and hyphens" do
      assert {:ok, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/task-1/sub.dir",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "accepts paths with parent references (path traversal is Safehouse's concern)" do
      assert {:ok, _} =
               Safehouse.build_command(
                 :claude_code,
                 "/workspace/../other",
                 [prompt: "Do it"] ++ @skip_check
               )
    end

    test "rejects non-string workspace path" do
      assert {:error, msg} =
               Safehouse.build_command(:claude_code, 123, [prompt: "Do it"] ++ @skip_check)

      assert msg =~ "invalid path type"
    end
  end

  describe "safehouse binary validation" do
    test "safehouse_available? returns boolean" do
      result = Safehouse.safehouse_available?()
      assert is_boolean(result)
    end

    test "build_command returns error when safehouse not found and check not skipped" do
      # Only run this test when safehouse is NOT installed
      unless Safehouse.safehouse_available?() do
        assert {:error, msg} =
                 Safehouse.build_command(:claude_code, "/workspace", prompt: "Do it")

        assert msg =~ "safehouse binary not found in PATH"
      end
    end
  end

  describe "build_command_list/3" do
    test "returns flat list with command as first element" do
      assert {:ok, list} =
               Safehouse.build_command_list(
                 :claude_code,
                 "/workspace/task-1",
                 [prompt: "Do it"] ++ @skip_check
               )

      assert hd(list) == "safehouse"
      assert "--" in list
      assert "claude" in list
    end

    test "returns error for unknown agent" do
      assert {:error, _} =
               Safehouse.build_command_list(
                 :nonexistent,
                 "/workspace",
                 [prompt: "Do it"] ++ @skip_check
               )
    end
  end
end
