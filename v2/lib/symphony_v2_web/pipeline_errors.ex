defmodule SymphonyV2Web.PipelineErrors do
  @moduledoc """
  Human-readable error message formatting for pipeline operations.

  Translates internal error tuples and atoms into user-friendly messages
  for display in LiveView flash notifications.
  """

  @spec format(term()) :: String.t()
  def format(:not_awaiting_plan_review),
    do: "This task is no longer awaiting plan review. The page has been refreshed."

  def format(:not_awaiting_final_review),
    do: "This task is no longer awaiting final review. The page has been refreshed."

  def format(:not_processing),
    do: "The pipeline is not currently processing a task."

  def format(:pipeline_idle),
    do: "The pipeline is idle. No task is being processed."

  def format(:self_review),
    do: "You cannot approve your own task."

  def format({:invalid_transition, from, to}),
    do: "Cannot move task from \"#{from}\" to \"#{to}\"."

  def format({:merge_failed, reason}),
    do: "Merge failed: #{inspect(reason)}"

  def format({:safehouse_not_found, msg}),
    do: "Agent sandbox not available: #{msg}"

  def format({:pr_parse_failed, _output}),
    do: "Failed to parse PR information from GitHub CLI output."

  def format(reason) when is_binary(reason), do: reason

  def format(reason), do: "Operation failed: #{inspect(reason)}"
end
