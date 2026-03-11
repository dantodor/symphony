defmodule SymphonyV2.Plans.SubtaskState do
  @moduledoc """
  Formal state machine for subtask status transitions.

  State machine:
    pending → dispatched
    dispatched → running, failed
    running → testing, failed
    testing → in_review, failed
    in_review → succeeded, failed, pending (retry)
    succeeded → pending (retry on task-level retry)
    failed → pending (retry)
  """

  @transitions %{
    "pending" => ["dispatched"],
    "dispatched" => ["running", "failed"],
    "running" => ["testing", "failed"],
    "testing" => ["in_review", "failed"],
    "in_review" => ["succeeded", "failed", "pending"],
    "succeeded" => ["pending"],
    "failed" => ["pending"]
  }

  @doc "Returns true if transitioning from `from` to `to` is valid."
  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "Returns the list of valid next statuses from the given status."
  @spec valid_next_statuses(String.t()) :: [String.t()]
  def valid_next_statuses(status), do: Map.get(@transitions, status, [])

  @doc "Returns the full transitions map."
  @spec transitions() :: map()
  def transitions, do: @transitions
end
