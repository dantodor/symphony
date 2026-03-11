defmodule SymphonyV2.SettingsTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Settings
  alias SymphonyV2.Settings.AppSetting

  describe "get_settings/0" do
    test "returns default settings when none exist" do
      setting = Settings.get_settings()
      assert %AppSetting{} = setting
      assert setting.test_command == "mix test"
      assert setting.planning_agent == "claude_code"
      assert setting.review_agent == "gemini_cli"
      assert setting.default_agent == "claude_code"
      assert setting.dangerously_skip_permissions == false
      assert setting.agent_timeout_ms == 600_000
      assert setting.max_retries == 2
    end

    test "returns existing settings" do
      Settings.get_settings()
      Settings.update_settings(%{"test_command" => "make test"})
      setting = Settings.get_settings()
      assert setting.test_command == "make test"
    end
  end

  describe "update_settings/1" do
    test "updates editable fields" do
      {:ok, setting} =
        Settings.update_settings(%{
          "test_command" => "npm test",
          "planning_agent" => "codex",
          "review_agent" => "claude_code",
          "default_agent" => "gemini_cli",
          "agent_timeout_ms" => "300000",
          "max_retries" => "5",
          "dangerously_skip_permissions" => "true"
        })

      assert setting.test_command == "npm test"
      assert setting.planning_agent == "codex"
      assert setting.review_agent == "claude_code"
      assert setting.default_agent == "gemini_cli"
      assert setting.agent_timeout_ms == 300_000
      assert setting.max_retries == 5
      assert setting.dangerously_skip_permissions == true
    end

    test "rejects invalid agent timeout" do
      {:error, changeset} = Settings.update_settings(%{"agent_timeout_ms" => "0"})
      assert errors_on(changeset).agent_timeout_ms
    end

    test "rejects negative max_retries" do
      {:error, changeset} = Settings.update_settings(%{"max_retries" => "-1"})
      assert errors_on(changeset).max_retries
    end

    test "rejects unknown agent type" do
      {:error, changeset} = Settings.update_settings(%{"planning_agent" => "nonexistent"})
      assert errors_on(changeset).planning_agent
    end

    test "updates review_failure_action" do
      {:ok, setting} = Settings.update_settings(%{"review_failure_action" => "fail"})
      assert setting.review_failure_action == "fail"
    end

    test "rejects invalid review_failure_action" do
      {:error, changeset} = Settings.update_settings(%{"review_failure_action" => "invalid"})
      assert errors_on(changeset).review_failure_action
    end

    test "review_failure_action defaults to auto_approve" do
      setting = Settings.get_settings()
      assert setting.review_failure_action == "auto_approve"
    end
  end

  describe "change_settings/2" do
    test "returns a changeset" do
      setting = Settings.get_settings()
      changeset = Settings.change_settings(setting)
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "custom agents CRUD" do
    test "list_custom_agents/0 returns empty list initially" do
      assert Settings.list_custom_agents() == []
    end

    test "create_custom_agent/1 creates a valid agent" do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "test_agent",
          "command" => "test-cli",
          "prompt_flag" => "-p"
        })

      assert agent.name == "test_agent"
      assert agent.command == "test-cli"
      assert agent.prompt_flag == "-p"
      assert agent.env_vars == []
    end

    test "create_custom_agent/1 with all fields" do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "full_agent",
          "command" => "full-cli",
          "prompt_flag" => "--prompt",
          "skip_permissions_flag" => "--no-confirm",
          "env_vars" => ["API_KEY", "SECRET"]
        })

      assert agent.skip_permissions_flag == "--no-confirm"
      assert agent.env_vars == ["API_KEY", "SECRET"]
    end

    test "create_custom_agent/1 rejects missing required fields" do
      {:error, changeset} = Settings.create_custom_agent(%{})
      errors = errors_on(changeset)
      assert errors.name
      assert errors.command
      assert errors.prompt_flag
    end

    test "create_custom_agent/1 rejects invalid name format" do
      {:error, changeset} =
        Settings.create_custom_agent(%{
          "name" => "Invalid-Name",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      assert errors_on(changeset).name
    end

    test "create_custom_agent/1 enforces unique name" do
      {:ok, _} =
        Settings.create_custom_agent(%{
          "name" => "unique_agent",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:error, changeset} =
        Settings.create_custom_agent(%{
          "name" => "unique_agent",
          "command" => "cmd2",
          "prompt_flag" => "-q"
        })

      assert errors_on(changeset).name
    end

    test "get_custom_agent!/1 returns agent" do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "get_test",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      found = Settings.get_custom_agent!(agent.id)
      assert found.id == agent.id
    end

    test "update_custom_agent/2 updates fields" do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "update_test",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:ok, updated} = Settings.update_custom_agent(agent, %{"command" => "new-cmd"})
      assert updated.command == "new-cmd"
    end

    test "delete_custom_agent/1 removes agent" do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "delete_test",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:ok, _} = Settings.delete_custom_agent(agent)
      assert_raise Ecto.NoResultsError, fn -> Settings.get_custom_agent!(agent.id) end
    end

    test "list_custom_agents/0 returns created agents" do
      {:ok, _} =
        Settings.create_custom_agent(%{
          "name" => "list_test",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      agents = Settings.list_custom_agents()
      assert length(agents) == 1
      assert hd(agents).name == "list_test"
    end
  end

  describe "command_installed?/1" do
    test "returns true for known commands" do
      assert Settings.command_installed?("sh")
    end

    test "returns false for unknown commands" do
      refute Settings.command_installed?("nonexistent_command_xyz_123")
    end
  end
end
