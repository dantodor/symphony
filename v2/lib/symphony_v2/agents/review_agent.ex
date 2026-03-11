defmodule SymphonyV2.Agents.ReviewAgent do
  @moduledoc """
  Orchestrates the review step for a subtask.

  Launches a review agent (different type from the executor) inside the
  workspace, waits for completion, then parses the resulting `review.json`
  to determine whether the subtask's work is approved or rejected.
  """

  require Logger

  alias SymphonyV2.Agents.AgentSupervisor
  alias SymphonyV2.Agents.ReviewParser
  alias SymphonyV2.Plans
  alias SymphonyV2.Plans.Subtask

  @review_filename "review.json"

  @doc """
  Runs the review agent for a subtask.

  1. Builds a review prompt with the subtask spec and git diff
  2. Creates an AgentRun record
  3. Launches the review agent via AgentProcess
  4. Waits for completion
  5. Parses review.json from workspace
  6. Updates subtask with verdict

  Returns `{:ok, review}` on success or `{:error, reason}` on failure.

  ## Options

  - `:agent_type` — review agent type (default: from AppConfig)
  - `:timeout_ms` — agent timeout (default: from AppConfig)
  - `:safehouse_opts` — additional safehouse options (default: `[]`)
  - `:supervisor` — AgentSupervisor to use (default: `AgentSupervisor`)
  - `:diff` — pre-computed diff string (skips git diff call)
  """
  @spec run(%Subtask{}, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Subtask{} = subtask, workspace, opts \\ []) do
    config = SymphonyV2.AppConfig.load()
    agent_type = Keyword.get(opts, :agent_type, String.to_atom(config.review_agent))
    timeout_ms = Keyword.get(opts, :timeout_ms, config.agent_timeout_ms)
    safehouse_opts = Keyword.get(opts, :safehouse_opts, [])
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)

    with :ok <- validate_different_agent(subtask, agent_type),
         {:ok, diff} <- get_diff(subtask, workspace, opts),
         prompt <- build_prompt(subtask, diff),
         {:ok, agent_run} <- create_agent_run(subtask, agent_type),
         {:ok, result} <-
           launch_agent(agent_run, agent_type, workspace, prompt, timeout_ms, safehouse_opts,
             supervisor: supervisor
           ),
         :ok <- check_agent_success(result),
         {:ok, review} <- parse_review(workspace),
         {:ok, _subtask} <- apply_verdict(subtask, review) do
      {:ok, review}
    else
      {:error, reason} = error ->
        Logger.error("Review failed",
          subtask_id: subtask.id,
          reason: inspect(reason)
        )

        handle_failure(subtask, reason)
        error
    end
  end

  @doc """
  Builds the review prompt for a subtask.

  The prompt includes the subtask spec, the git diff of changes, and
  instructions for the review agent to critically evaluate the work.
  """
  @spec build_prompt(%Subtask{}, String.t()) :: String.t()
  def build_prompt(%Subtask{} = subtask, diff) do
    """
    You are a code review agent. Your job is to critically review code changes made by another agent.

    ## Subtask Specification

    **Title:** #{subtask.title}

    **Spec:** #{subtask.spec}

    ## Changes Made

    ```diff
    #{diff}
    ```

    ## Review Instructions

    Critically evaluate the changes against the specification. Look specifically for:

    1. **Corner-cutting** — Did the agent take shortcuts instead of implementing properly?
    2. **Meaningless tests** — Are tests actually verifying behavior, or are they trivial/tautological?
    3. **Hardcoded values** — Are there hardcoded values designed to pass specific assertions rather than implement real logic?
    4. **Skipped requirements** — Does the implementation address all parts of the specification?
    5. **Code quality** — Is the code well-structured, properly named, and following existing patterns?

    ## Output

    Write a file called `review.json` to the workspace root with this exact structure:

    ```json
    {
      "verdict": "approved" or "rejected",
      "reasoning": "Detailed explanation of your assessment...",
      "issues": [
        {
          "severity": "critical" or "major" or "minor" or "nit",
          "description": "Description of the issue..."
        }
      ]
    }
    ```

    Rules:
    - verdict must be either "approved" or "rejected"
    - reasoning must explain your assessment in detail
    - issues is an optional array — include it if there are specific problems to flag
    - Use "rejected" if there are any critical or major issues
    - Use "approved" if the implementation correctly satisfies the specification
    - Be thorough but fair — reject only for substantive problems, not style preferences
    """
    |> String.trim()
  end

  @doc """
  Returns the expected review file path within a workspace.
  """
  @spec review_file_path(String.t()) :: String.t()
  def review_file_path(workspace) do
    Path.join(workspace, @review_filename)
  end

  # --- Private ---

  defp validate_different_agent(subtask, review_agent_type) do
    executor_type = String.to_atom(subtask.agent_type)

    if executor_type == review_agent_type do
      {:error, {:same_agent_type, subtask.agent_type}}
    else
      :ok
    end
  end

  defp get_diff(subtask, workspace, opts) do
    case Keyword.get(opts, :diff) do
      nil -> compute_diff(subtask, workspace)
      diff when is_binary(diff) -> {:ok, diff}
    end
  end

  defp compute_diff(subtask, workspace) do
    base_branch = subtask.branch_name |> determine_base_branch()
    head_branch = subtask.branch_name

    case SymphonyV2.GitOps.diff(workspace, base_branch, head_branch) do
      {:ok, diff} when diff != "" -> {:ok, diff}
      {:ok, ""} -> {:error, :no_changes}
      {:error, reason} -> {:error, {:diff_failed, reason}}
    end
  end

  defp determine_base_branch(branch_name) do
    # Branch naming: symphony/<task_id>/step-<position>-<slug>
    # For step-1, base is "main". For step-N, base is step-(N-1) branch.
    case Regex.run(~r/^symphony\/([^\/]+)\/step-(\d+)-/, branch_name) do
      [_, _task_id, position_str] ->
        position = String.to_integer(position_str)

        if position <= 1 do
          "main"
        else
          # We need to find the previous branch. Since we only have the naming
          # convention, we'll use main as the base. The caller can provide
          # a more accurate base via the diff option.
          "main"
        end

      _ ->
        "main"
    end
  end

  defp create_agent_run(subtask, agent_type) do
    Plans.create_agent_run(%{
      subtask_id: subtask.id,
      agent_type: Atom.to_string(agent_type),
      attempt_number: (subtask.retry_count || 0) + 1,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
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

  defp parse_review(workspace) do
    review_path = review_file_path(workspace)
    ReviewParser.parse(review_path)
  end

  defp apply_verdict(subtask, %{verdict: "approved"} = review) do
    Plans.update_subtask(subtask, %{
      status: "succeeded",
      review_verdict: "approved",
      review_reasoning: review.reasoning
    })
  end

  defp apply_verdict(subtask, %{verdict: "rejected"} = review) do
    Plans.update_subtask(subtask, %{
      review_verdict: "rejected",
      review_reasoning: review.reasoning,
      last_error: review.reasoning
    })
  end

  defp handle_failure(subtask, reason) do
    error_message = format_error(reason)
    Logger.error("Subtask review failed: #{error_message}", subtask_id: subtask.id)

    # Update subtask with error info (don't transition to failed — let Pipeline handle retries)
    Plans.update_subtask(subtask, %{last_error: error_message})
  end

  defp format_error({:file_not_found, path}), do: "Review file not found: #{path}"
  defp format_error(:invalid_json), do: "Review file contains invalid JSON"
  defp format_error(:invalid_review_format), do: "Review file is not a valid JSON object"
  defp format_error(:missing_verdict), do: "Review file missing 'verdict' field"

  defp format_error({:invalid_verdict, v}),
    do: "Invalid verdict '#{v}' (must be approved/rejected)"

  defp format_error(:verdict_must_be_string), do: "Review verdict must be a string"
  defp format_error(:missing_reasoning), do: "Review file missing 'reasoning' field"
  defp format_error(:empty_reasoning), do: "Review reasoning is empty"
  defp format_error(:reasoning_must_be_string), do: "Review reasoning must be a string"
  defp format_error(:issues_must_be_list), do: "Review issues must be a list"
  defp format_error({:invalid_issues, errors}), do: "Invalid issues: #{Enum.join(errors, "; ")}"
  defp format_error({:agent_failed, code}), do: "Review agent failed with exit code #{code}"
  defp format_error(:agent_timeout), do: "Review agent timed out"

  defp format_error({:same_agent_type, type}),
    do: "Review agent must differ from executor (both #{type})"

  defp format_error(:no_changes), do: "No changes found to review"
  defp format_error({:diff_failed, reason}), do: "Failed to compute diff: #{inspect(reason)}"
  defp format_error(other), do: "Review failed: #{inspect(other)}"
end
