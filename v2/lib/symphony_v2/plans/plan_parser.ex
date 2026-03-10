defmodule SymphonyV2.Plans.PlanParser do
  @moduledoc """
  Parses and validates plan.json files produced by the planning agent.

  The planning agent writes a `plan.json` to the workspace root containing
  an ordered list of subtasks. This module reads, decodes, and validates
  the structure before it can be used to create database records.
  """

  alias SymphonyV2.Agents.AgentRegistry

  @type subtask_entry :: %{
          position: pos_integer(),
          title: String.t(),
          spec: String.t(),
          agent_type: String.t()
        }

  @doc """
  Parses a plan.json file at the given path.

  Reads the file, decodes JSON, and validates the structure.
  Returns `{:ok, [subtask_entry]}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, [subtask_entry()]} | {:error, term()}
  def parse(file_path) do
    with {:ok, content} <- read_file(file_path),
         {:ok, decoded} <- decode_json(content),
         {:ok, tasks} <- extract_tasks(decoded),
         :ok <- validate_tasks(tasks) do
      {:ok, normalize_tasks(tasks)}
    end
  end

  @doc """
  Parses a plan from a raw map (already decoded JSON).

  Useful when the plan data is already in memory (e.g., from tests).
  Returns `{:ok, [subtask_entry]}` or `{:error, reason}`.
  """
  @spec parse_map(map()) :: {:ok, [subtask_entry()]} | {:error, term()}
  def parse_map(data) when is_map(data) do
    with {:ok, tasks} <- extract_tasks(data),
         :ok <- validate_tasks(tasks) do
      {:ok, normalize_tasks(tasks)}
    end
  end

  # --- Private ---

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp extract_tasks(%{"tasks" => [_ | _] = tasks}) do
    {:ok, tasks}
  end

  defp extract_tasks(%{"tasks" => []}) do
    {:error, :empty_tasks}
  end

  defp extract_tasks(%{"tasks" => _}) do
    {:error, :tasks_not_a_list}
  end

  defp extract_tasks(_) do
    {:error, :missing_tasks_key}
  end

  defp validate_tasks(tasks) do
    with :ok <- validate_task_fields(tasks),
         :ok <- validate_positions(tasks),
         :ok <- validate_agent_types(tasks) do
      :ok
    end
  end

  defp validate_task_fields(tasks) do
    errors =
      tasks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {task, index} ->
        validate_single_task(task, index)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:invalid_tasks, errors}}
    end
  end

  defp validate_single_task(task, index) when is_map(task) do
    []
    |> maybe_add_error(
      !is_integer(task["position"]) || task["position"] < 1,
      "task #{index}: position must be a positive integer"
    )
    |> maybe_add_error(
      !non_empty_string?(task["title"]),
      "task #{index}: title must be a non-empty string"
    )
    |> maybe_add_error(
      !non_empty_string?(task["spec"]),
      "task #{index}: spec must be a non-empty string"
    )
    |> maybe_add_error(
      !non_empty_string?(task["agent_type"]),
      "task #{index}: agent_type must be a non-empty string"
    )
  end

  defp validate_single_task(_task, index) do
    ["task #{index}: must be a map/object"]
  end

  defp validate_positions(tasks) do
    positions = Enum.map(tasks, & &1["position"])
    expected = Enum.to_list(1..length(tasks))

    if Enum.sort(positions) != expected do
      {:error, {:invalid_positions, positions, expected}}
    else
      :ok
    end
  end

  defp validate_agent_types(tasks) do
    invalid =
      tasks
      |> Enum.map(& &1["agent_type"])
      |> Enum.reject(&AgentRegistry.registered?/1)

    case invalid do
      [] -> :ok
      types -> {:error, {:unknown_agent_types, Enum.uniq(types)}}
    end
  end

  defp normalize_tasks(tasks) do
    tasks
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(fn task ->
      %{
        position: task["position"],
        title: task["title"],
        spec: task["spec"],
        agent_type: task["agent_type"]
      }
    end)
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_), do: false

  defp maybe_add_error(errors, true, message), do: [message | errors]
  defp maybe_add_error(errors, false, _message), do: errors
end
