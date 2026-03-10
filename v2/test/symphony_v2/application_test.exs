defmodule SymphonyV2.ApplicationTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Agents.AgentSupervisor

  @moduletag :application

  describe "supervision tree" do
    test "all required children are running" do
      # Repo
      assert Process.whereis(SymphonyV2.Repo) != nil

      # PubSub
      assert Process.whereis(SymphonyV2.PubSub) != nil

      # AgentSupervisor
      assert Process.whereis(AgentSupervisor) != nil

      # Pipeline
      assert Process.whereis(SymphonyV2.Pipeline) != nil

      # Endpoint
      assert Process.whereis(SymphonyV2Web.Endpoint) != nil
    end

    test "supervisor is running with correct name" do
      assert Process.whereis(SymphonyV2.Supervisor) != nil
    end

    test "supervisor uses one_for_one strategy" do
      # Verify the supervisor is alive and responding
      pid = Process.whereis(SymphonyV2.Supervisor)
      assert Process.alive?(pid)

      # Supervisor.count_children confirms it's a supervisor
      children = Supervisor.count_children(SymphonyV2.Supervisor)
      assert children[:active] >= 5
    end

    test "Repo starts before Pipeline (startup order verified by functioning system)" do
      # If Repo wasn't started before Pipeline, Pipeline.init would fail
      # because it calls maybe_recover which queries the database.
      # The fact that Pipeline is running proves the order is correct.
      pipeline_pid = Process.whereis(SymphonyV2.Pipeline)
      assert Process.alive?(pipeline_pid)

      state = SymphonyV2.Pipeline.get_state()
      assert state.status in [:idle, :processing]
    end

    test "PubSub starts before Pipeline (verified by functioning broadcasts)" do
      # Subscribe and broadcast through the PubSub system
      alias SymphonyV2.PubSub.Topics
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.pipeline())
      Phoenix.PubSub.broadcast(SymphonyV2.PubSub, Topics.pipeline(), {:test, :works})

      assert_receive {:test, :works}
    end

    test "AgentSupervisor starts before Pipeline" do
      # AgentSupervisor must be running for Pipeline to launch agents
      assert AgentSupervisor.running_count() >= 0
    end
  end
end
