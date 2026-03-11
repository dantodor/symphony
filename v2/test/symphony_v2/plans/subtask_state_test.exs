defmodule SymphonyV2.Plans.SubtaskStateTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Plans.SubtaskState

  describe "valid_transition?/2" do
    test "pending can transition to dispatched" do
      assert SubtaskState.valid_transition?("pending", "dispatched")
    end

    test "pending cannot transition to running" do
      refute SubtaskState.valid_transition?("pending", "running")
    end

    test "pending cannot transition to succeeded" do
      refute SubtaskState.valid_transition?("pending", "succeeded")
    end

    test "dispatched can transition to running" do
      assert SubtaskState.valid_transition?("dispatched", "running")
    end

    test "dispatched can transition to failed" do
      assert SubtaskState.valid_transition?("dispatched", "failed")
    end

    test "dispatched cannot transition to succeeded" do
      refute SubtaskState.valid_transition?("dispatched", "succeeded")
    end

    test "running can transition to testing" do
      assert SubtaskState.valid_transition?("running", "testing")
    end

    test "running can transition to failed" do
      assert SubtaskState.valid_transition?("running", "failed")
    end

    test "running cannot transition to succeeded" do
      refute SubtaskState.valid_transition?("running", "succeeded")
    end

    test "testing can transition to in_review" do
      assert SubtaskState.valid_transition?("testing", "in_review")
    end

    test "testing can transition to failed" do
      assert SubtaskState.valid_transition?("testing", "failed")
    end

    test "in_review can transition to succeeded" do
      assert SubtaskState.valid_transition?("in_review", "succeeded")
    end

    test "in_review can transition to failed" do
      assert SubtaskState.valid_transition?("in_review", "failed")
    end

    test "in_review can transition to pending (retry)" do
      assert SubtaskState.valid_transition?("in_review", "pending")
    end

    test "succeeded can transition to pending (task-level retry)" do
      assert SubtaskState.valid_transition?("succeeded", "pending")
    end

    test "succeeded cannot transition to failed" do
      refute SubtaskState.valid_transition?("succeeded", "failed")
    end

    test "failed can transition to pending (retry)" do
      assert SubtaskState.valid_transition?("failed", "pending")
    end

    test "failed cannot transition to running" do
      refute SubtaskState.valid_transition?("failed", "running")
    end

    test "unknown status returns false" do
      refute SubtaskState.valid_transition?("unknown", "pending")
    end
  end

  describe "valid_next_statuses/1" do
    test "returns dispatched for pending" do
      assert SubtaskState.valid_next_statuses("pending") == ["dispatched"]
    end

    test "returns running and failed for dispatched" do
      assert SubtaskState.valid_next_statuses("dispatched") == ["running", "failed"]
    end

    test "returns testing and failed for running" do
      assert SubtaskState.valid_next_statuses("running") == ["testing", "failed"]
    end

    test "returns in_review and failed for testing" do
      assert SubtaskState.valid_next_statuses("testing") == ["in_review", "failed"]
    end

    test "returns succeeded, failed, and pending for in_review" do
      assert SubtaskState.valid_next_statuses("in_review") == ["succeeded", "failed", "pending"]
    end

    test "returns pending for succeeded" do
      assert SubtaskState.valid_next_statuses("succeeded") == ["pending"]
    end

    test "returns pending for failed" do
      assert SubtaskState.valid_next_statuses("failed") == ["pending"]
    end

    test "returns empty list for unknown status" do
      assert SubtaskState.valid_next_statuses("unknown") == []
    end
  end

  describe "transitions/0" do
    test "returns the full transitions map" do
      transitions = SubtaskState.transitions()
      assert is_map(transitions)
      assert Map.has_key?(transitions, "pending")
      assert Map.has_key?(transitions, "failed")
      assert map_size(transitions) == 7
    end
  end
end
