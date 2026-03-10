defmodule SymphonyV2.PubSub.TopicsTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.PubSub.Topics

  describe "pipeline/0" do
    test "returns pipeline topic string" do
      assert Topics.pipeline() == "pipeline"
    end
  end

  describe "task/1" do
    test "returns task topic with id" do
      id = "abc-123"
      assert Topics.task(id) == "task:abc-123"
    end

    test "returns task topic with UUID" do
      id = Ecto.UUID.generate()
      assert Topics.task(id) == "task:#{id}"
    end
  end

  describe "subtask/1" do
    test "returns subtask topic with id" do
      id = "def-456"
      assert Topics.subtask(id) == "subtask:def-456"
    end
  end

  describe "agent_output/1" do
    test "returns agent_output topic with id" do
      id = "ghi-789"
      assert Topics.agent_output(id) == "agent_output:ghi-789"
    end
  end
end
