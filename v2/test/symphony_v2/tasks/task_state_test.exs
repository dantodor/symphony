defmodule SymphonyV2.Tasks.TaskStateTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Tasks.TaskState

  describe "valid_transition?/2" do
    test "draft → awaiting_review is valid" do
      assert TaskState.valid_transition?("draft", "awaiting_review")
    end

    test "draft → planning is valid" do
      assert TaskState.valid_transition?("draft", "planning")
    end

    test "awaiting_review → planning is valid" do
      assert TaskState.valid_transition?("awaiting_review", "planning")
    end

    test "planning → plan_review is valid" do
      assert TaskState.valid_transition?("planning", "plan_review")
    end

    test "planning → failed is valid" do
      assert TaskState.valid_transition?("planning", "failed")
    end

    test "plan_review → executing is valid" do
      assert TaskState.valid_transition?("plan_review", "executing")
    end

    test "plan_review → planning is valid (re-plan)" do
      assert TaskState.valid_transition?("plan_review", "planning")
    end

    test "executing → completed is valid" do
      assert TaskState.valid_transition?("executing", "completed")
    end

    test "executing → failed is valid" do
      assert TaskState.valid_transition?("executing", "failed")
    end

    test "failed → draft is valid (restart)" do
      assert TaskState.valid_transition?("failed", "draft")
    end

    test "completed is terminal — no transitions" do
      refute TaskState.valid_transition?("completed", "draft")
      refute TaskState.valid_transition?("completed", "failed")
      refute TaskState.valid_transition?("completed", "executing")
    end

    # Invalid transitions
    test "draft → completed is invalid" do
      refute TaskState.valid_transition?("draft", "completed")
    end

    test "draft → executing is invalid" do
      refute TaskState.valid_transition?("draft", "executing")
    end

    test "draft → failed is invalid" do
      refute TaskState.valid_transition?("draft", "failed")
    end

    test "awaiting_review → executing is invalid" do
      refute TaskState.valid_transition?("awaiting_review", "executing")
    end

    test "planning → executing is invalid (must go through plan_review)" do
      refute TaskState.valid_transition?("planning", "executing")
    end

    test "executing → planning is invalid" do
      refute TaskState.valid_transition?("executing", "planning")
    end

    test "unknown status returns false" do
      refute TaskState.valid_transition?("nonexistent", "draft")
    end
  end

  describe "valid_next_statuses/1" do
    test "returns valid next statuses for each status" do
      assert TaskState.valid_next_statuses("draft") == ["awaiting_review", "planning"]
      assert TaskState.valid_next_statuses("awaiting_review") == ["planning"]
      assert TaskState.valid_next_statuses("planning") == ["plan_review", "failed"]
      assert TaskState.valid_next_statuses("plan_review") == ["executing", "planning"]
      assert TaskState.valid_next_statuses("executing") == ["completed", "failed"]
      assert TaskState.valid_next_statuses("failed") == ["draft", "executing"]
      assert TaskState.valid_next_statuses("completed") == []
    end

    test "returns empty list for unknown status" do
      assert TaskState.valid_next_statuses("nonexistent") == []
    end
  end

  describe "transitions/0" do
    test "returns the full transitions map" do
      transitions = TaskState.transitions()
      assert is_map(transitions)
      assert Map.has_key?(transitions, "draft")
      assert Map.has_key?(transitions, "completed")
      assert map_size(transitions) == 7
    end
  end
end
