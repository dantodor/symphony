defmodule SymphonyV2.PubSub.Topics do
  @moduledoc """
  Centralized PubSub topic definitions.

  All PubSub topics used in the application are defined here to ensure
  consistent naming and provide a single reference for all topic patterns.

  ## Topics

  - `"pipeline"` — Pipeline-level events (started, idle, paused, resumed)
  - `"task:<id>"` — Task-level events (step changes, completion, failure)
  - `"subtask:<id>"` — Subtask-level events (started, running, testing, reviewing, etc.)
  - `"agent_output:<id>"` — Agent output streaming and completion
  """

  @doc "Pipeline-level events topic."
  @spec pipeline() :: String.t()
  def pipeline, do: "pipeline"

  @doc "Task-level events topic for a specific task."
  @spec task(Ecto.UUID.t()) :: String.t()
  def task(id), do: "task:#{id}"

  @doc "Subtask-level events topic for a specific subtask."
  @spec subtask(Ecto.UUID.t()) :: String.t()
  def subtask(id), do: "subtask:#{id}"

  @doc "Agent output streaming topic for a specific agent run."
  @spec agent_output(Ecto.UUID.t()) :: String.t()
  def agent_output(id), do: "agent_output:#{id}"
end
