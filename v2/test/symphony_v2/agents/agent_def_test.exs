defmodule SymphonyV2.Agents.AgentDefTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Agents.AgentDef

  describe "new/1 with keyword list" do
    test "creates from keyword list" do
      assert {:ok, agent} =
               AgentDef.new(name: :test, command: "test-cli", prompt_flag: "-p")

      assert agent.name == :test
      assert agent.command == "test-cli"
      assert agent.prompt_flag == "-p"
      assert agent.skip_permissions_flag == nil
      assert agent.env_vars == []
    end
  end

  describe "new/1 with map" do
    test "creates from map with atom keys" do
      assert {:ok, agent} =
               AgentDef.new(%{
                 name: :test,
                 command: "test-cli",
                 prompt_flag: "-p",
                 skip_permissions_flag: "--skip",
                 env_vars: ["KEY1", "KEY2"]
               })

      assert agent.name == :test
      assert agent.command == "test-cli"
      assert agent.prompt_flag == "-p"
      assert agent.skip_permissions_flag == "--skip"
      assert agent.env_vars == ["KEY1", "KEY2"]
    end

    test "creates from map with string keys" do
      assert {:ok, agent} =
               AgentDef.new(%{
                 "name" => "my_agent",
                 "command" => "my-cli",
                 "prompt_flag" => "--prompt"
               })

      assert agent.name == :my_agent
      assert agent.command == "my-cli"
      assert agent.prompt_flag == "--prompt"
    end

    test "returns error when name is missing" do
      assert {:error, msg} = AgentDef.new(%{command: "cli", prompt_flag: "-p"})
      assert String.contains?(msg, "name")
    end

    test "returns error when command is missing" do
      assert {:error, msg} = AgentDef.new(%{name: :test, prompt_flag: "-p"})
      assert String.contains?(msg, "command")
    end

    test "returns error when prompt_flag is missing" do
      assert {:error, msg} = AgentDef.new(%{name: :test, command: "cli"})
      assert String.contains?(msg, "prompt_flag")
    end

    test "returns error listing all missing fields" do
      assert {:error, msg} = AgentDef.new(%{})
      assert String.contains?(msg, "name")
      assert String.contains?(msg, "command")
      assert String.contains?(msg, "prompt_flag")
    end
  end
end
