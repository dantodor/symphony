defmodule SymphonyV2.Agents.AgentRegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Agents.AgentDef
  alias SymphonyV2.Agents.AgentRegistry

  describe "all/0" do
    test "returns all built-in agents" do
      agents = AgentRegistry.all()
      names = Enum.map(agents, & &1.name)
      assert :claude_code in names
      assert :codex in names
      assert :gemini_cli in names
      assert :opencode in names
    end

    test "all agents are AgentDef structs" do
      for agent <- AgentRegistry.all() do
        assert %AgentDef{} = agent
        assert is_atom(agent.name)
        assert is_binary(agent.command)
        assert is_binary(agent.prompt_flag)
        assert is_list(agent.env_vars)
      end
    end
  end

  describe "get/1 with atom" do
    test "returns known agent" do
      assert {:ok, %AgentDef{name: :claude_code}} = AgentRegistry.get(:claude_code)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentRegistry.get(:nonexistent)
    end
  end

  describe "get/1 with string" do
    test "returns known agent" do
      assert {:ok, %AgentDef{name: :codex}} = AgentRegistry.get("codex")
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentRegistry.get("nonexistent_agent")
    end
  end

  describe "agent_names/0" do
    test "returns atom names of all agents" do
      names = AgentRegistry.agent_names()
      assert is_list(names)
      assert :claude_code in names
      assert :codex in names
    end
  end

  describe "agent_type_strings/0" do
    test "returns string names of all agents" do
      names = AgentRegistry.agent_type_strings()
      assert "claude_code" in names
      assert "codex" in names
      assert "gemini_cli" in names
      assert "opencode" in names
    end
  end

  describe "registered?/1" do
    test "returns true for known agents" do
      assert AgentRegistry.registered?(:claude_code)
      assert AgentRegistry.registered?("codex")
    end

    test "returns false for unknown agents" do
      refute AgentRegistry.registered?(:nonexistent)
      refute AgentRegistry.registered?("nonexistent")
    end
  end

  describe "build_command/3" do
    test "builds command without skip permissions" do
      assert {:ok, {"claude", ["-p", "do stuff"]}} =
               AgentRegistry.build_command(:claude_code, "do stuff")
    end

    test "builds command with skip permissions" do
      assert {:ok, {"claude", ["-p", "do stuff", "--dangerously-skip-permissions"]}} =
               AgentRegistry.build_command(:claude_code, "do stuff", skip_permissions: true)
    end

    test "skip permissions flag omitted when agent has none" do
      assert {:ok, {"gemini", ["-p", "do stuff"]}} =
               AgentRegistry.build_command(:gemini_cli, "do stuff", skip_permissions: true)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentRegistry.build_command(:nonexistent, "prompt")
    end

    test "builds codex command correctly" do
      assert {:ok, {"codex", ["-q", "fix bug"]}} =
               AgentRegistry.build_command(:codex, "fix bug")

      assert {:ok, {"codex", ["-q", "fix bug", "--dangerously-bypass-approvals-and-sandbox"]}} =
               AgentRegistry.build_command(:codex, "fix bug", skip_permissions: true)
    end
  end

  describe "builtin_agents/0" do
    test "returns exactly 4 built-in agents" do
      assert length(AgentRegistry.builtin_agents()) == 4
    end
  end

  describe "claude_code agent definition" do
    test "has correct configuration" do
      {:ok, agent} = AgentRegistry.get(:claude_code)
      assert agent.command == "claude"
      assert agent.prompt_flag == "-p"
      assert agent.skip_permissions_flag == "--dangerously-skip-permissions"
      assert "ANTHROPIC_API_KEY" in agent.env_vars
    end
  end

  describe "codex agent definition" do
    test "has correct configuration" do
      {:ok, agent} = AgentRegistry.get(:codex)
      assert agent.command == "codex"
      assert agent.prompt_flag == "-q"
      assert agent.skip_permissions_flag == "--dangerously-bypass-approvals-and-sandbox"
      assert "OPENAI_API_KEY" in agent.env_vars
    end
  end

  describe "gemini_cli agent definition" do
    test "has correct configuration" do
      {:ok, agent} = AgentRegistry.get(:gemini_cli)
      assert agent.command == "gemini"
      assert agent.prompt_flag == "-p"
      assert agent.skip_permissions_flag == nil
      assert "GEMINI_API_KEY" in agent.env_vars
    end
  end

  describe "opencode agent definition" do
    test "has correct configuration" do
      {:ok, agent} = AgentRegistry.get(:opencode)
      assert agent.command == "opencode"
      assert agent.prompt_flag == "-p"
      assert agent.skip_permissions_flag == nil
      assert agent.env_vars == []
    end
  end

  describe "normalize_agent_type/1" do
    test "returns atom for registered agent type" do
      assert {:ok, :claude_code} = AgentRegistry.normalize_agent_type("claude_code")
      assert {:ok, :codex} = AgentRegistry.normalize_agent_type("codex")
      assert {:ok, :gemini_cli} = AgentRegistry.normalize_agent_type("gemini_cli")
      assert {:ok, :opencode} = AgentRegistry.normalize_agent_type("opencode")
    end

    test "returns error for unknown agent type" do
      assert {:error, :unknown_agent} = AgentRegistry.normalize_agent_type("nonexistent")
    end

    test "returns error for arbitrary string (prevents atom exhaustion)" do
      assert {:error, :unknown_agent} =
               AgentRegistry.normalize_agent_type("arbitrary_string_#{System.unique_integer()}")
    end
  end

  describe "custom agents via config" do
    test "loads custom agents from application config" do
      original = Application.get_env(:symphony_v2, AgentRegistry)

      Application.put_env(:symphony_v2, AgentRegistry,
        custom_agents: [
          %{name: :my_agent, command: "my-cli", prompt_flag: "--ask", env_vars: ["MY_KEY"]}
        ]
      )

      assert AgentRegistry.registered?(:my_agent)
      assert {:ok, agent} = AgentRegistry.get(:my_agent)
      assert agent.command == "my-cli"
      assert agent.prompt_flag == "--ask"
      assert "MY_KEY" in agent.env_vars

      if original do
        Application.put_env(:symphony_v2, AgentRegistry, original)
      else
        Application.delete_env(:symphony_v2, AgentRegistry)
      end
    end

    test "ignores invalid custom agent definitions" do
      original = Application.get_env(:symphony_v2, AgentRegistry)

      Application.put_env(:symphony_v2, AgentRegistry,
        custom_agents: [
          %{name: :valid, command: "valid-cli", prompt_flag: "-p"},
          %{name: :invalid}
        ]
      )

      assert AgentRegistry.registered?(:valid)
      refute AgentRegistry.registered?(:invalid)

      if original do
        Application.put_env(:symphony_v2, AgentRegistry, original)
      else
        Application.delete_env(:symphony_v2, AgentRegistry)
      end
    end
  end
end
