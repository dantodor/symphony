defmodule SymphonyV2.Agents.PlanningAgent do
  @moduledoc """
  Orchestrates the planning step for a task.

  Launches the configured planning agent inside the workspace, waits for
  completion, then parses the resulting `plan.json` to create execution
  plan and subtask records in the database.
  """

  require Logger

  alias SymphonyV2.Agents.AgentRegistry
  alias SymphonyV2.Agents.AgentSupervisor
  alias SymphonyV2.Plans
  alias SymphonyV2.Plans.PlanParser
  alias SymphonyV2.Tasks
  alias SymphonyV2.Tasks.Task

  @plan_filename "plan.json"

  @doc """
  Runs the planning agent for a task.

  1. Builds a planning prompt from the task
  2. Creates an AgentRun record
  3. Launches the planning agent via AgentProcess
  4. Waits for completion
  5. Parses plan.json from workspace
  6. Creates ExecutionPlan and Subtask records
  7. Transitions task to plan_review (or failed)

  Returns `{:ok, plan}` on success or `{:error, reason}` on failure.

  ## Options

  - `:agent_type` — planning agent type (default: from AppConfig)
  - `:timeout_ms` — agent timeout (default: from AppConfig)
  - `:safehouse_opts` — additional safehouse options (default: `[]`)
  - `:supervisor` — AgentSupervisor to use (default: `AgentSupervisor`)
  """
  @spec run(%Task{}, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Task{} = task, workspace, opts \\ []) do
    config = SymphonyV2.AppConfig.load()
    agent_type = Keyword.get(opts, :agent_type, String.to_atom(config.planning_agent))
    timeout_ms = Keyword.get(opts, :timeout_ms, config.agent_timeout_ms)
    safehouse_opts = Keyword.get(opts, :safehouse_opts, [])
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)

    prompt = build_prompt(task)

    with {:ok, agent_run} <- create_agent_run(task, agent_type),
         {:ok, result} <-
           launch_agent(agent_run, agent_type, workspace, prompt, timeout_ms, safehouse_opts,
             supervisor: supervisor
           ),
         :ok <- check_agent_success(result),
         {:ok, subtask_entries} <- parse_plan(workspace),
         {:ok, plan} <- create_plan_records(task, subtask_entries, workspace),
         {:ok, _task} <- transition_task(task, "plan_review") do
      {:ok, plan}
    else
      {:error, reason} = error ->
        Logger.error("Planning failed",
          task_id: task.id,
          reason: inspect(reason)
        )

        handle_failure(task, reason)
        error
    end
  end

  @doc """
  Builds the planning prompt for a task.

  The prompt includes the task details and instructions for the planning
  agent to explore the codebase and write a plan.json file.
  """
  @spec build_prompt(%Task{}) :: String.t()
  def build_prompt(%Task{} = task) do
    agent_types = AgentRegistry.agent_type_strings() |> Enum.join(", ")

    """
    You are a planning agent. Your job is to analyze a codebase and decompose a high-level task into ordered subtasks.

    ## Task

    **Title:** #{task.title}

    **Description:** #{task.description}
    #{if task.relevant_files, do: "\n**Relevant files/constraints:** #{task.relevant_files}\n", else: ""}
    ## Instructions

    1. Explore the codebase thoroughly to understand the architecture, patterns, and conventions.
    2. Decompose the task into small, ordered subtasks that can be executed sequentially.
    3. Each subtask should be a discrete, implementable unit that produces testable results.
    4. Assign the best agent type for each subtask based on its characteristics.
    5. Write the plan to a file called `plan.json` in the workspace root.

    ## Available Agent Types

    #{agent_types}

    ## Plan File Format

    Write a JSON file with this exact structure:

    ```json
    {
      "tasks": [
        {
          "position": 1,
          "title": "Short description",
          "spec": "Detailed specification of what to implement...",
          "agent_type": "claude_code"
        }
      ]
    }
    ```

    Rules:
    - Positions must be sequential starting from 1
    - Each subtask must have a title, spec, and agent_type
    - The spec should be detailed enough for a coding agent to implement without additional context
    - Agent types must be one of: #{agent_types}
    - Order subtasks so each builds on the previous one's work
    - Keep subtasks focused — one concern per subtask
    """
    |> String.trim()
  end

  @doc """
  Returns the expected plan file path within a workspace.
  """
  @spec plan_file_path(String.t()) :: String.t()
  def plan_file_path(workspace) do
    Path.join(workspace, @plan_filename)
  end

  # --- Private ---

  defp create_agent_run(task, agent_type) do
    # We need a subtask-less agent run for planning. Create a temporary plan first.
    with {:ok, plan} <-
           Plans.create_plan(%{task_id: task.id, status: "planning"}),
         {:ok, _subtask} <-
           create_planning_subtask(plan, agent_type),
         plan <- Plans.get_plan!(plan.id),
         subtask <- hd(plan.subtasks) do
      Plans.create_agent_run(%{
        subtask_id: subtask.id,
        agent_type: Atom.to_string(agent_type),
        attempt_number: 1,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end
  end

  defp create_planning_subtask(plan, agent_type) do
    Plans.create_subtasks_from_plan(plan, [
      %{
        position: 1,
        title: "Planning",
        spec: "Analyze codebase and create execution plan",
        agent_type: Atom.to_string(agent_type)
      }
    ])
  end

  defp launch_agent(agent_run, agent_type, workspace, prompt, timeout_ms, safehouse_opts, opts) do
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)

    agent_opts = %{
      agent_type: agent_type,
      workspace: workspace,
      agent_run_id: agent_run.id,
      prompt: prompt,
      caller: self(),
      timeout_ms: timeout_ms,
      safehouse_opts: safehouse_opts
    }

    case AgentSupervisor.start_agent(supervisor, agent_opts) do
      {:ok, _pid} ->
        receive do
          {:agent_complete, result} -> {:ok, result}
        after
          timeout_ms + 5_000 ->
            {:error, :agent_launch_timeout}
        end

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp check_agent_success(%{status: :succeeded}), do: :ok

  defp check_agent_success(%{status: :failed, exit_code: code}) do
    {:error, {:agent_failed, code}}
  end

  defp check_agent_success(%{status: :timeout}) do
    {:error, :agent_timeout}
  end

  defp parse_plan(workspace) do
    plan_path = plan_file_path(workspace)
    PlanParser.parse(plan_path)
  end

  defp create_plan_records(task, subtask_entries, workspace) do
    plan_path = plan_file_path(workspace)

    # Read raw plan for storage
    raw_plan =
      case File.read(plan_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    # Find the existing plan (created during agent run setup)
    case Plans.get_plan_by_task_id(task.id) do
      nil ->
        {:error, :plan_not_found}

      plan ->
        # Update the plan with raw_plan and plan_file_path
        with {:ok, plan} <-
               update_plan_with_results(plan, raw_plan, plan_path),
             {:ok, subtasks} <- Plans.create_subtasks_from_plan(plan, subtask_entries) do
          {:ok, Plans.get_plan!(plan.id) |> Map.put(:subtasks, subtasks)}
        end
    end
  end

  defp update_plan_with_results(plan, raw_plan, plan_file_path) do
    # Delete the planning subtask first (it was only used to hold the agent run)
    cleanup_planning_subtasks(plan)

    plan
    |> Ecto.Changeset.change(%{
      raw_plan: raw_plan,
      plan_file_path: plan_file_path,
      status: "awaiting_review"
    })
    |> SymphonyV2.Repo.update()
  end

  defp cleanup_planning_subtasks(plan) do
    import Ecto.Query

    SymphonyV2.Plans.Subtask
    |> where([s], s.execution_plan_id == ^plan.id and s.title == "Planning")
    |> SymphonyV2.Repo.delete_all()
  end

  defp transition_task(task, new_status) do
    Tasks.update_task_status(task, new_status)
  end

  defp handle_failure(task, reason) do
    error_message = format_error(reason)
    Logger.error("Task planning failed: #{error_message}", task_id: task.id)

    # Try to transition task to failed
    case Tasks.update_task_status(task, "failed") do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp format_error({:file_not_found, path}), do: "Plan file not found: #{path}"
  defp format_error(:invalid_json), do: "Plan file contains invalid JSON"
  defp format_error(:empty_tasks), do: "Plan file contains no tasks"
  defp format_error(:missing_tasks_key), do: "Plan file missing 'tasks' key"
  defp format_error({:invalid_tasks, errors}), do: "Invalid tasks: #{Enum.join(errors, "; ")}"

  defp format_error({:invalid_positions, _, _}),
    do: "Task positions are not sequential starting from 1"

  defp format_error({:unknown_agent_types, types}),
    do: "Unknown agent types: #{Enum.join(types, ", ")}"

  defp format_error({:agent_failed, code}), do: "Planning agent failed with exit code #{code}"
  defp format_error(:agent_timeout), do: "Planning agent timed out"
  defp format_error(other), do: "Planning failed: #{inspect(other)}"
end
