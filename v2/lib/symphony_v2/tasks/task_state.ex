defmodule SymphonyV2.Tasks.TaskState do
  @moduledoc """
  Defines the valid state transitions for tasks.

  State machine:
    draft → awaiting_review (if review_requested)
    draft → planning (if not review_requested)
    awaiting_review → planning (on approval by non-creator)
    planning → plan_review (plan generated)
    planning → failed (planning agent failed)
    plan_review → executing (plan approved)
    plan_review → planning (plan rejected, re-plan)
    executing → completed (all subtasks done + human approves stack)
    executing → failed (retries exhausted)
    completed → (terminal)
    failed → draft (human restarts)
  """

  @transitions %{
    "draft" => ["awaiting_review", "planning"],
    "awaiting_review" => ["planning"],
    "planning" => ["plan_review", "failed"],
    "plan_review" => ["executing", "planning"],
    "executing" => ["completed", "failed"],
    "failed" => ["draft", "executing"],
    "completed" => []
  }

  @doc "Returns true if transitioning from `from` to `to` is valid."
  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(from, to) do
    to in Map.get(@transitions, from, [])
  end

  @doc "Returns the list of valid next statuses from the given status."
  @spec valid_next_statuses(String.t()) :: [String.t()]
  def valid_next_statuses(status) do
    Map.get(@transitions, status, [])
  end

  @doc "Returns the full transitions map."
  @spec transitions() :: map()
  def transitions, do: @transitions
end
