defmodule SymphonyV2.AppConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.AppConfig

  describe "struct defaults" do
    test "has expected default values" do
      config = %AppConfig{}
      assert config.repo_path == nil
      assert config.workspace_root == nil
      assert config.test_command == "mix test"
      assert config.planning_agent == "claude_code"
      assert config.review_agent == "gemini_cli"
      assert config.default_agent == "claude_code"
      assert config.dangerously_skip_permissions == false
      assert config.agent_timeout_ms == 600_000
      assert config.max_retries == 2
      assert config.review_failure_action == :auto_approve
    end
  end

  describe "load/0" do
    test "loads from application environment" do
      original = Application.get_env(:symphony_v2, AppConfig)

      Application.put_env(:symphony_v2, AppConfig,
        repo_path: "/tmp/test-repo",
        workspace_root: "/tmp/test-workspaces",
        test_command: "make test",
        planning_agent: "codex",
        review_agent: "claude_code",
        default_agent: "codex",
        dangerously_skip_permissions: true,
        agent_timeout_ms: 300_000,
        max_retries: 5
      )

      config = AppConfig.load()
      assert config.repo_path == "/tmp/test-repo"
      assert config.workspace_root == "/tmp/test-workspaces"
      assert config.test_command == "make test"
      assert config.planning_agent == "codex"
      assert config.review_agent == "claude_code"
      assert config.default_agent == "codex"
      assert config.dangerously_skip_permissions == true
      assert config.agent_timeout_ms == 300_000
      assert config.max_retries == 5

      # Restore
      if original, do: Application.put_env(:symphony_v2, AppConfig, original)
    end

    test "returns defaults when no config is set" do
      original = Application.get_env(:symphony_v2, AppConfig)
      Application.delete_env(:symphony_v2, AppConfig)

      config = AppConfig.load()
      assert config.test_command == "mix test"
      assert config.planning_agent == "claude_code"
      assert config.max_retries == 2

      if original, do: Application.put_env(:symphony_v2, AppConfig, original)
    end
  end

  describe "validate/1" do
    setup do
      # Create temp directories for validation
      repo_path = Path.join(System.tmp_dir!(), "symphony_test_repo_#{:rand.uniform(100_000)}")
      workspace_root = Path.join(System.tmp_dir!(), "symphony_test_ws_#{:rand.uniform(100_000)}")
      File.mkdir_p!(repo_path)
      File.mkdir_p!(workspace_root)

      on_exit(fn ->
        File.rm_rf!(repo_path)
        File.rm_rf!(workspace_root)
      end)

      {:ok, repo_path: repo_path, workspace_root: workspace_root}
    end

    test "validates a valid config", %{repo_path: repo_path, workspace_root: workspace_root} do
      config = %AppConfig{repo_path: repo_path, workspace_root: workspace_root}
      assert {:ok, ^config} = AppConfig.validate(config)
    end

    test "returns error when repo_path is nil" do
      config = %AppConfig{repo_path: nil, workspace_root: System.tmp_dir!()}
      assert {:error, errors} = AppConfig.validate(config)
      assert "repo_path is required" in errors
    end

    test "returns error when repo_path does not exist" do
      config = %AppConfig{
        repo_path: "/nonexistent/path/xyz",
        workspace_root: System.tmp_dir!()
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "repo_path does not exist"))
    end

    test "returns error when workspace_root is nil" do
      config = %AppConfig{repo_path: System.tmp_dir!(), workspace_root: nil}
      assert {:error, errors} = AppConfig.validate(config)
      assert "workspace_root is required" in errors
    end

    test "returns error when workspace_root does not exist" do
      config = %AppConfig{
        repo_path: System.tmp_dir!(),
        workspace_root: "/nonexistent/path/xyz"
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "workspace_root does not exist"))
    end

    test "returns error for unknown planning_agent", %{
      repo_path: repo_path,
      workspace_root: workspace_root
    } do
      config = %AppConfig{
        repo_path: repo_path,
        workspace_root: workspace_root,
        planning_agent: "nonexistent_agent"
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "planning_agent"))
    end

    test "returns error for unknown review_agent", %{
      repo_path: repo_path,
      workspace_root: workspace_root
    } do
      config = %AppConfig{
        repo_path: repo_path,
        workspace_root: workspace_root,
        review_agent: "unknown"
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "review_agent"))
    end

    test "returns error for unknown default_agent", %{
      repo_path: repo_path,
      workspace_root: workspace_root
    } do
      config = %AppConfig{
        repo_path: repo_path,
        workspace_root: workspace_root,
        default_agent: "unknown"
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "default_agent"))
    end

    test "returns error for invalid agent_timeout_ms", %{
      repo_path: repo_path,
      workspace_root: workspace_root
    } do
      config = %AppConfig{
        repo_path: repo_path,
        workspace_root: workspace_root,
        agent_timeout_ms: -1
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "agent_timeout_ms"))
    end

    test "returns error for invalid max_retries", %{
      repo_path: repo_path,
      workspace_root: workspace_root
    } do
      config = %AppConfig{
        repo_path: repo_path,
        workspace_root: workspace_root,
        max_retries: -1
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "max_retries"))
    end

    test "accumulates multiple errors" do
      config = %AppConfig{
        repo_path: nil,
        workspace_root: nil,
        planning_agent: "bad",
        agent_timeout_ms: 0,
        max_retries: -1
      }

      assert {:error, errors} = AppConfig.validate(config)
      assert length(errors) >= 4
    end

    test "returns error when workspace_root is not writable", %{repo_path: repo_path} do
      ro_dir = Path.join(System.tmp_dir!(), "symphony_ro_#{:rand.uniform(100_000)}")
      File.mkdir_p!(ro_dir)
      File.chmod!(ro_dir, 0o444)

      config = %AppConfig{repo_path: repo_path, workspace_root: ro_dir}
      assert {:error, errors} = AppConfig.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "not writable"))

      # Cleanup
      File.chmod!(ro_dir, 0o755)
      File.rm_rf!(ro_dir)
    end
  end

  describe "review_failure_action" do
    test "defaults to :auto_approve" do
      config = %AppConfig{}
      assert config.review_failure_action == :auto_approve
    end

    test "can be set via application config" do
      original = Application.get_env(:symphony_v2, AppConfig)

      Application.put_env(:symphony_v2, AppConfig,
        repo_path: "/tmp/test-repo",
        workspace_root: "/tmp/test-workspaces",
        review_failure_action: :fail
      )

      config = AppConfig.load()
      assert config.review_failure_action == :fail

      if original,
        do: Application.put_env(:symphony_v2, AppConfig, original),
        else: Application.delete_env(:symphony_v2, AppConfig)
    end
  end

  describe "merge_db_settings logging" do
    import ExUnit.CaptureLog

    test "logs warning when DB settings cannot be loaded" do
      # In test env without Repo checkout, db_settings() raises and hits rescue
      original = Application.get_env(:symphony_v2, AppConfig)

      Application.put_env(:symphony_v2, AppConfig,
        repo_path: "/tmp/test-repo",
        workspace_root: "/tmp/test-workspaces"
      )

      log =
        capture_log([level: :warning], fn ->
          AppConfig.load()
        end)

      assert log =~ "Failed to load DB settings"

      if original, do: Application.put_env(:symphony_v2, AppConfig, original)
    end
  end

  describe "load_and_validate/0" do
    test "loads and validates in one step" do
      original = Application.get_env(:symphony_v2, AppConfig)

      Application.put_env(:symphony_v2, AppConfig,
        repo_path: System.tmp_dir!(),
        workspace_root: System.tmp_dir!()
      )

      assert {:ok, config} = AppConfig.load_and_validate()
      assert config.repo_path == System.tmp_dir!()

      if original, do: Application.put_env(:symphony_v2, AppConfig, original)
    end
  end
end
