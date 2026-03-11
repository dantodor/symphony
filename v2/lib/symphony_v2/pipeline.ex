defmodule SymphonyV2.Pipeline do
  @moduledoc """
  Core execution pipeline GenServer.

  Drives the entire task lifecycle: planning → plan review → subtask execution
  (agent → test → commit/push/PR → review) → final review → merge.

  Runs one task at a time. Tasks queue up and execute in order.
  """

  use GenServer

  require Logger

  alias SymphonyV2.Agents.AgentSupervisor
  alias SymphonyV2.Agents.PlanningAgent
  alias SymphonyV2.Agents.ReviewAgent
  alias SymphonyV2.AppConfig
  alias SymphonyV2.GitOps
  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Settings
  alias SymphonyV2.Tasks
  alias SymphonyV2.TestRunner
  alias SymphonyV2.Workspace

  @type step ::
          :planning
          | :awaiting_plan_review
          | :executing_subtask
          | :testing
          | :reviewing
          | :awaiting_final_review
          | :merging
          | nil

  @type state :: %{
          status: :idle | :processing,
          current_task_id: Ecto.UUID.t() | nil,
          current_subtask_id: Ecto.UUID.t() | nil,
          current_step: step(),
          workspace: String.t() | nil,
          config: AppConfig.t() | nil,
          paused: boolean()
        }

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check the queue for a task to process."
  @spec check_queue(GenServer.server()) :: :ok
  def check_queue(server \\ __MODULE__) do
    GenServer.cast(server, :check_queue)
  end

  @doc "Approve the current plan. Triggers execution."
  @spec approve_plan(GenServer.server()) :: :ok | {:error, term()}
  def approve_plan(server \\ __MODULE__) do
    GenServer.call(server, :approve_plan)
  end

  @doc "Reject the current plan. Re-runs planning."
  @spec reject_plan(GenServer.server()) :: :ok | {:error, term()}
  def reject_plan(server \\ __MODULE__) do
    GenServer.call(server, :reject_plan)
  end

  @doc "Approve the final review. Triggers merge."
  @spec approve_final(GenServer.server()) :: :ok | {:error, term()}
  def approve_final(server \\ __MODULE__) do
    GenServer.call(server, :approve_final)
  end

  @doc "Reject the final review with feedback. Fails the task."
  @spec reject_final(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def reject_final(feedback, server \\ __MODULE__) do
    GenServer.call(server, {:reject_final, feedback})
  end

  @doc "Get the current pipeline state."
  @spec get_state(GenServer.server()) :: state()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc "Reset the pipeline to idle state. Used in tests to clear stale in-memory state."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc "Pause the pipeline. Stops after the current subtask completes."
  @spec pause(GenServer.server()) :: :ok
  def pause(server \\ __MODULE__) do
    GenServer.cast(server, :pause)
  end

  @doc "Resume a paused pipeline."
  @spec resume(GenServer.server()) :: :ok
  def resume(server \\ __MODULE__) do
    GenServer.cast(server, :resume)
  end

  @doc "Retry a failed task from its failed subtask."
  @spec retry_task(GenServer.server()) :: :ok | {:error, term()}
  def retry_task(server \\ __MODULE__) do
    GenServer.call(server, :retry_task)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config) || AppConfig.load()

    state = %{
      status: :idle,
      current_task_id: nil,
      current_subtask_id: nil,
      current_step: nil,
      workspace: nil,
      config: config,
      paused: false
    }

    # Recover from DB on startup
    state = maybe_recover(state)

    # If recovered into an active state, schedule continuation
    if state.status == :processing do
      schedule_recovery_continuation(state)
    end

    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Pipeline shutting down",
      reason: inspect(reason),
      status: state.status,
      task_id: state.current_task_id,
      step: state.current_step
    )

    # State is already persisted to DB via Tasks/Plans context calls,
    # so recovery on restart will pick up where we left off.
    :ok
  end

  @impl true
  def handle_cast(:check_queue, %{status: :processing} = state) do
    {:noreply, state}
  end

  def handle_cast(:check_queue, %{status: :idle} = state) do
    case Tasks.next_queued_task() do
      nil ->
        {:noreply, state}

      task ->
        state = start_task(task, state)
        {:noreply, state}
    end
  end

  def handle_cast(:pause, %{status: :processing} = state) do
    Logger.info("Pipeline paused", task_id: state.current_task_id)
    broadcast(:pipeline, {:pipeline_paused, state.current_task_id})
    persist_paused(true)
    {:noreply, %{state | paused: true}}
  end

  def handle_cast(:pause, state), do: {:noreply, state}

  def handle_cast(:resume, %{paused: true} = state) do
    Logger.info("Pipeline resumed", task_id: state.current_task_id)
    broadcast(:pipeline, {:pipeline_resumed, state.current_task_id})
    state = %{state | paused: false}
    persist_paused(false)

    if state.status == :processing do
      case state.current_step do
        :executing_subtask ->
          send(self(), {:continue, :execute_next_subtask})

        :planning ->
          task = Tasks.get_task!(state.current_task_id)
          send(self(), {:continue, {:run_planning, task}})

        # Steps waiting for human input — no continuation needed
        :awaiting_plan_review ->
          :ok

        :awaiting_final_review ->
          :ok

        # Active steps (testing, reviewing) complete on their own
        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast(:resume, state), do: {:noreply, state}

  @impl true
  def handle_call(:approve_plan, _from, %{current_step: :awaiting_plan_review} = state) do
    state = do_approve_plan(state)
    {:reply, :ok, state}
  end

  def handle_call(:approve_plan, _from, state) do
    {:reply, {:error, :not_awaiting_plan_review}, state}
  end

  def handle_call(:reject_plan, _from, %{current_step: :awaiting_plan_review} = state) do
    state = do_reject_plan(state)
    {:reply, :ok, state}
  end

  def handle_call(:reject_plan, _from, state) do
    {:reply, {:error, :not_awaiting_plan_review}, state}
  end

  def handle_call(:approve_final, _from, %{current_step: :awaiting_final_review} = state) do
    state = do_approve_final(state)
    {:reply, :ok, state}
  end

  def handle_call(:approve_final, _from, state) do
    {:reply, {:error, :not_awaiting_final_review}, state}
  end

  def handle_call(
        {:reject_final, feedback},
        _from,
        %{current_step: :awaiting_final_review} = state
      ) do
    state = do_reject_final(state, feedback)
    {:reply, :ok, state}
  end

  def handle_call({:reject_final, _feedback}, _from, state) do
    {:reply, {:error, :not_awaiting_final_review}, state}
  end

  def handle_call(:retry_task, _from, %{status: :idle} = state) do
    # Find the most recent failed task and retry it
    case Tasks.list_tasks_by_status("failed") do
      [task | _] ->
        new_state = do_retry_task(task, state)

        if new_state.status == :processing do
          {:reply, :ok, new_state}
        else
          {:reply, {:error, :retry_failed}, state}
        end

      [] ->
        {:reply, {:error, :no_failed_task}, state}
    end
  end

  def handle_call(:retry_task, _from, state) do
    {:reply, {:error, :pipeline_busy}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, Map.delete(state, :config), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, return_idle(state)}
  end

  @impl true
  def handle_info({:continue, :execute_next_subtask}, state) do
    state = execute_next_subtask(state)
    {:noreply, state}
  end

  def handle_info({:continue, :check_queue}, state) do
    check_queue(self())
    {:noreply, state}
  end

  def handle_info({:continue, {:run_planning, task}}, state) do
    {:noreply, run_planning(state, task)}
  end

  # --- Task lifecycle ---

  defp start_task(task, state) do
    Logger.info("Pipeline starting task", task_id: task.id, title: task.title)
    broadcast(:pipeline, {:pipeline_started, task.id})

    state = %{state | status: :processing, current_task_id: task.id, current_step: :planning}

    run_planning(state, task)
  end

  defp run_planning(state, task) do
    config = state.config

    case ensure_workspace(config, task.id) do
      {:ok, ws} ->
        do_run_planning(state, task, config, ws)

      {:error, reason} ->
        fail_task(task, "Workspace setup failed: #{inspect(reason)}")
        send(self(), {:continue, :check_queue})
        return_idle(state)
    end
  end

  defp do_run_planning(state, task, config, workspace) do
    broadcast(:task, task.id, {:task_step, :planning})
    state = %{state | workspace: workspace}

    planning_opts = [
      timeout_ms: config.agent_timeout_ms,
      safehouse_opts: []
    ]

    case PlanningAgent.run(task, workspace, planning_opts) do
      {:ok, _plan} ->
        handle_planning_success(state, task, config)

      {:error, reason} ->
        Logger.error("Planning failed", task_id: task.id, reason: inspect(reason))
        broadcast(:task, task.id, {:task_failed, reason})
        fail_current_task(state, "Planning failed: #{inspect(reason)}")
    end
  end

  defp handle_planning_success(state, task, config) do
    if config.dangerously_skip_permissions do
      Logger.info("Auto-approving plan (dangerously_skip_permissions)", task_id: task.id)
      task = Tasks.get_task!(task.id)
      do_approve_plan_for_task(task, state)
    else
      # Transition task and plan to plan_review
      task = Tasks.get_task!(task.id)
      plan = Plans.get_plan_by_task_id(task.id)

      with {:ok, _task} <- Tasks.update_task_status(task, "plan_review"),
           {:ok, _plan} <- Plans.update_plan_status(plan, "plan_review") do
        broadcast(:task, task.id, {:task_step, :awaiting_plan_review})
        %{state | current_step: :awaiting_plan_review}
      else
        {:error, reason} ->
          Logger.error("Failed to transition to plan_review",
            task_id: task.id,
            reason: inspect(reason)
          )

          fail_current_task(state, "Failed to enter plan review: #{inspect(reason)}")
      end
    end
  end

  defp do_approve_plan(state) do
    task = Tasks.get_task!(state.current_task_id)
    do_approve_plan_for_task(task, state)
  end

  defp do_approve_plan_for_task(task, state) do
    plan = Plans.get_plan_by_task_id(task.id)

    with {:ok, _plan} <- Plans.update_plan_status(plan, "executing"),
         {:ok, task} <- Tasks.update_task_status(task, "executing") do
      broadcast(:task, task.id, {:task_step, :executing_subtask})

      state = %{state | current_task_id: task.id, current_step: :executing_subtask}

      execute_next_subtask(state)
    else
      {:error, reason} ->
        Logger.error("Failed to approve plan", task_id: task.id, reason: inspect(reason))
        fail_current_task(state, "Failed to approve plan: #{inspect(reason)}")
    end
  end

  defp do_reject_plan(state) do
    task = Tasks.get_task!(state.current_task_id)

    case Tasks.update_task_status(task, "planning") do
      {:ok, task} ->
        broadcast(:task, task.id, {:task_step, :planning})
        run_planning(%{state | current_step: :planning}, task)

      {:error, reason} ->
        Logger.error("Failed to reject plan", task_id: task.id, reason: inspect(reason))
        fail_current_task(state, "Failed to reject plan: #{inspect(reason)}")
    end
  end

  # --- Subtask execution ---

  defp execute_next_subtask(%{paused: true} = state) do
    Logger.info("Pipeline paused, waiting for resume", task_id: state.current_task_id)
    broadcast(:task, state.current_task_id, {:task_step, :paused})
    state
  end

  defp execute_next_subtask(state) do
    plan = Plans.get_plan_by_task_id(state.current_task_id)

    case Plans.next_pending_subtask(plan) do
      nil ->
        # All subtasks done
        if Plans.all_subtasks_succeeded?(plan) do
          handle_all_subtasks_complete(state)
        else
          # Some subtask(s) failed
          Logger.error("Not all subtasks succeeded", task_id: state.current_task_id)
          fail_current_task(state, "Not all subtasks completed successfully")
        end

      subtask ->
        execute_subtask(state, subtask)
    end
  end

  defp execute_subtask(state, subtask) do
    workspace = state.workspace
    plan = Plans.get_plan_by_task_id(state.current_task_id)
    task = Tasks.get_task!(state.current_task_id)

    state = %{state | current_subtask_id: subtask.id, current_step: :executing_subtask}
    broadcast(:subtask, subtask.id, {:subtask_started, subtask.position})

    with {:ok, branch_name} <- create_subtask_branch(workspace, task.id, subtask, plan),
         {:ok, subtask} <- dispatch_subtask(subtask, branch_name) do
      launch_and_wait_for_agent(state, subtask)
    else
      {:error, reason} ->
        Logger.error("Subtask setup failed", subtask_id: subtask.id, reason: inspect(reason))
        handle_subtask_failure(state, subtask, "Subtask setup failed: #{inspect(reason)}")
    end
  end

  defp dispatch_subtask(subtask, branch_name) do
    Plans.update_subtask(subtask, %{branch_name: branch_name, status: "dispatched"})
  end

  defp launch_and_wait_for_agent(state, subtask) do
    config = state.config
    prompt = build_subtask_prompt(subtask)
    agent_type = String.to_atom(subtask.agent_type)

    agent_run_attrs = %{
      subtask_id: subtask.id,
      agent_type: subtask.agent_type,
      attempt_number: (subtask.retry_count || 0) + 1,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    with {:ok, agent_run} <- Plans.create_agent_run(agent_run_attrs),
         {:ok, subtask} <- Plans.update_subtask_status(subtask, "running") do
      broadcast(:subtask, subtask.id, {:subtask_running, subtask.position})

      agent_opts = %{
        agent_type: agent_type,
        workspace: state.workspace,
        agent_run_id: agent_run.id,
        prompt: prompt,
        caller: self(),
        timeout_ms: config.agent_timeout_ms,
        safehouse_opts: []
      }

      run_agent_and_handle_result(state, subtask, agent_opts, config.agent_timeout_ms)
    else
      {:error, reason} ->
        Logger.error("Agent launch setup failed",
          subtask_id: subtask.id,
          reason: inspect(reason)
        )

        handle_subtask_failure(state, subtask, "Agent launch setup failed: #{inspect(reason)}")
    end
  end

  defp run_agent_and_handle_result(state, subtask, agent_opts, timeout_ms) do
    case AgentSupervisor.start_agent(agent_opts) do
      {:ok, pid} ->
        # Monitor the agent process for crash detection
        Process.monitor(pid)

        receive do
          {:agent_complete, result} ->
            handle_agent_complete(state, subtask, result)

          {:DOWN, _ref, :process, ^pid, reason} when reason != :normal ->
            Logger.warning("Agent process crashed",
              subtask_id: subtask.id,
              reason: inspect(reason)
            )

            handle_agent_complete(state, subtask, %{status: :failed, exit_code: 1})
        after
          timeout_ms + 10_000 ->
            handle_agent_complete(state, subtask, %{status: :timeout})
        end

      {:error, reason} ->
        Logger.error("Failed to start agent",
          subtask_id: subtask.id,
          reason: inspect(reason)
        )

        handle_subtask_failure(state, subtask, "Agent failed to start: #{inspect(reason)}")
    end
  end

  defp handle_agent_complete(state, subtask, %{status: :succeeded}) do
    workspace = state.workspace

    # Check for changes
    if GitOps.has_changes?(workspace) do
      run_tests(state, subtask)
    else
      handle_subtask_failure(state, subtask, "Agent made no changes")
    end
  end

  defp handle_agent_complete(state, subtask, %{status: :failed, exit_code: code}) do
    handle_subtask_failure(state, subtask, "Agent failed with exit code #{code}")
  end

  defp handle_agent_complete(state, subtask, %{status: :timeout}) do
    handle_subtask_failure(state, subtask, "Agent timed out")
  end

  # --- Testing step ---

  defp run_tests(state, subtask) do
    config = state.config
    workspace = state.workspace

    {:ok, subtask} = Plans.update_subtask_status(subtask, "testing")
    broadcast(:subtask, subtask.id, {:subtask_testing, subtask.position})
    state = %{state | current_step: :testing}

    case TestRunner.run_and_persist(workspace, config.test_command, subtask) do
      {:ok, %{passed: true}} ->
        commit_and_push(state, subtask)

      {:ok, %{passed: false, output: output}} ->
        handle_subtask_failure(state, subtask, "Tests failed:\n#{truncate(output, 2000)}")

      {:error, reason} ->
        handle_subtask_failure(state, subtask, "Test runner error: #{inspect(reason)}")
    end
  end

  # --- Commit, push, PR ---

  defp commit_and_push(state, subtask) do
    workspace = state.workspace
    task = Tasks.get_task!(state.current_task_id)

    commit_msg = "#{subtask.title}\n\nSubtask #{subtask.position} for task: #{task.title}"

    with {:ok, commit_sha} <- GitOps.stage_and_commit(workspace, commit_msg),
         :ok <- GitOps.push(workspace, subtask.branch_name),
         {:ok, files} <- GitOps.changed_files(workspace) do
      # Determine PR base branch
      base_branch = pr_base_branch(task.id, subtask)

      pr_opts = %{
        head: subtask.branch_name,
        base: base_branch,
        title: "[Symphony] #{subtask.title}",
        body:
          "Subtask #{subtask.position}/#{subtask_count(task.id)} for: **#{task.title}**\n\n#{subtask.spec}"
      }

      case GitOps.GitHub.create_pr(workspace, pr_opts) do
        {:ok, %{url: url, number: number}} ->
          {:ok, subtask} =
            Plans.update_subtask(subtask, %{
              commit_sha: commit_sha,
              files_changed: files,
              pr_url: url,
              pr_number: number
            })

          run_review(state, subtask)

        {:error, reason} ->
          Logger.warning("PR creation failed, continuing without PR",
            subtask_id: subtask.id,
            reason: inspect(reason)
          )

          # PR creation failure is non-fatal — continue to review
          {:ok, subtask} =
            Plans.update_subtask(subtask, %{
              commit_sha: commit_sha,
              files_changed: files
            })

          run_review(state, subtask)
      end
    else
      {:error, :nothing_to_commit} ->
        handle_subtask_failure(state, subtask, "Nothing to commit after tests passed")

      {:error, reason} ->
        handle_subtask_failure(state, subtask, "Git operations failed: #{inspect(reason)}")
    end
  end

  # --- Review step ---

  defp run_review(state, subtask) do
    workspace = state.workspace

    {:ok, subtask} = Plans.update_subtask_status(subtask, "in_review")
    broadcast(:subtask, subtask.id, {:subtask_reviewing, subtask.position})
    state = %{state | current_step: :reviewing}

    # Compute diff for review
    base_branch = pr_base_branch(state.current_task_id, subtask)

    review_opts = [
      timeout_ms: state.config.agent_timeout_ms,
      diff: get_diff_for_review(workspace, base_branch, subtask.branch_name)
    ]

    case ReviewAgent.run(subtask, workspace, review_opts) do
      {:ok, %{verdict: "approved"}} ->
        broadcast(:subtask, subtask.id, {:subtask_succeeded, subtask.position})
        # Subtask already marked as succeeded by ReviewAgent
        advance_to_next_subtask(state)

      {:ok, %{verdict: "rejected", reasoning: reasoning}} ->
        handle_subtask_failure(state, subtask, "Review rejected: #{reasoning}")

      {:error, {:same_agent_type, _}} ->
        # Review agent is same type as executor — skip review, auto-approve
        Logger.warning("Skipping review — same agent type", subtask_id: subtask.id)

        {:ok, _subtask} =
          Plans.update_subtask(subtask, %{
            status: "succeeded",
            review_verdict: "skipped",
            review_reasoning: "Review skipped — same agent type as executor"
          })

        broadcast(:subtask, subtask.id, {:subtask_succeeded, subtask.position})
        advance_to_next_subtask(state)

      {:error, reason} ->
        case state.config.review_failure_action do
          :fail ->
            handle_subtask_failure(state, subtask, "Review failed: #{inspect(reason)}")

          _auto_approve ->
            Logger.warning("Review failed, auto-approving subtask",
              subtask_id: subtask.id,
              reason: inspect(reason)
            )

            {:ok, _subtask} =
              Plans.update_subtask(subtask, %{
                status: "succeeded",
                review_verdict: "skipped",
                review_reasoning: "Review failed: #{inspect(reason)}"
              })

            broadcast(:subtask, subtask.id, {:subtask_succeeded, subtask.position})
            advance_to_next_subtask(state)
        end
    end
  end

  # --- Subtask retry logic ---

  defp handle_subtask_failure(state, subtask, error_message) do
    config = state.config
    max_retries = config.max_retries
    current_retries = subtask.retry_count || 0

    Logger.warning("Subtask failed",
      subtask_id: subtask.id,
      retry_count: current_retries,
      max_retries: max_retries,
      error: error_message
    )

    broadcast(:subtask, subtask.id, {:subtask_failed, subtask.position, error_message})

    if current_retries < max_retries do
      retry_subtask(state, subtask, error_message)
    else
      # Retries exhausted
      {:ok, _subtask} =
        Plans.update_subtask(subtask, %{
          status: "failed",
          last_error: error_message
        })

      fail_current_task(
        state,
        "Subtask '#{subtask.title}' failed after #{current_retries + 1} attempts: #{error_message}"
      )
    end
  end

  defp retry_subtask(state, subtask, error_message) do
    workspace = state.workspace

    Logger.info("Retrying subtask",
      subtask_id: subtask.id,
      attempt: (subtask.retry_count || 0) + 2
    )

    # Reset branch state
    GitOps.reset_hard(workspace)
    GitOps.clean(workspace)

    # Transition to failed first (if not already failed/pending), then reset for retry.
    # If still pending (failed before dispatch), use update_subtask to record the error.
    subtask =
      case subtask.status do
        "failed" ->
          subtask

        "pending" ->
          # Failed before even dispatching — just record the error/retry count
          {:ok, updated} =
            Plans.update_subtask(subtask, %{
              retry_count: (subtask.retry_count || 0) + 1,
              last_error: error_message
            })

          updated

        _ ->
          {:ok, failed_subtask} = Plans.update_subtask_status(subtask, "failed")
          failed_subtask
      end

    subtask =
      if subtask.status != "pending" do
        {:ok, reset} = Plans.reset_subtask_for_retry(subtask, error_message)
        reset
      else
        subtask
      end

    broadcast(:subtask, subtask.id, {:subtask_retrying, subtask.position, subtask.retry_count})

    # Re-execute
    send(self(), {:continue, :execute_next_subtask})
    %{state | current_step: :executing_subtask}
  end

  # --- Subtask advancement ---

  defp advance_to_next_subtask(state) do
    send(self(), {:continue, :execute_next_subtask})
    %{state | current_subtask_id: nil, current_step: :executing_subtask}
  end

  defp handle_all_subtasks_complete(state) do
    task = Tasks.get_task!(state.current_task_id)

    if state.config.dangerously_skip_permissions do
      Logger.info("Auto-approving final review (dangerously_skip_permissions)", task_id: task.id)
      do_merge(state)
    else
      broadcast(:task, task.id, {:task_step, :awaiting_final_review})
      %{state | current_step: :awaiting_final_review}
    end
  end

  # --- Final review and merge ---

  defp do_approve_final(state) do
    do_merge(state)
  end

  defp do_reject_final(state, feedback) do
    Logger.info("Final review rejected", task_id: state.current_task_id, feedback: feedback)
    fail_current_task(state, "Final review rejected: #{feedback}")
  end

  defp do_merge(state) do
    workspace = state.workspace
    task = Tasks.get_task!(state.current_task_id)
    plan = Plans.get_plan_by_task_id(task.id)

    state = %{state | current_step: :merging}
    broadcast(:task, task.id, {:task_step, :merging})

    # Get branch names in order
    subtasks = plan.subtasks |> Enum.sort_by(& &1.position)
    branch_names = Enum.map(subtasks, & &1.branch_name) |> Enum.reject(&is_nil/1)
    pr_numbers = Enum.map(subtasks, & &1.pr_number) |> Enum.reject(&is_nil/1)

    # Rebase stack onto main
    case GitOps.rebase_stack_onto_main(workspace, branch_names) do
      :ok ->
        # Force push rebased branches
        Enum.each(branch_names, fn branch ->
          GitOps.checkout(workspace, branch)
          GitOps.force_push(workspace, branch)
        end)

        # Merge PRs bottom-up
        case GitOps.GitHub.merge_stack(workspace, pr_numbers) do
          {:ok, _merged} ->
            complete_task(state)

          {:error, {:merge_failed_at, number, reason}} ->
            Logger.error("Merge failed", pr_number: number, reason: inspect(reason))
            mark_subtask_failed(subtasks, :pr_number, number, "Merge failed: #{inspect(reason)}")
            fail_current_task(state, "Merge failed at PR ##{number}: #{inspect(reason)}")
        end

      {:error, {:conflict, branch}} ->
        Logger.error("Rebase conflict", branch: branch, task_id: task.id)
        mark_subtask_failed(subtasks, :branch_name, branch, "Rebase conflict on branch #{branch}")
        fail_current_task(state, "Rebase conflict on branch #{branch}")

      {:error, reason} ->
        Logger.error("Rebase failed", task_id: task.id, reason: inspect(reason))
        fail_current_task(state, "Rebase failed: #{inspect(reason)}")
    end
  end

  # --- Task completion ---

  defp complete_task(state) do
    task = Tasks.get_task!(state.current_task_id)

    case Tasks.update_task_status(task, "completed") do
      {:ok, task} ->
        Logger.info("Task completed", task_id: task.id)
        broadcast(:task, task.id, {:task_completed, task.id})
        broadcast(:pipeline, {:pipeline_idle, task.id})

        # Optionally cleanup workspace
        cleanup_workspace(state)

        idle_state = return_idle(state)
        send(self(), {:continue, :check_queue})
        idle_state

      {:error, reason} ->
        Logger.error("Failed to mark task completed", task_id: task.id, reason: inspect(reason))
        return_idle(state)
    end
  end

  defp fail_current_task(state, error_message) do
    task = Tasks.get_task!(state.current_task_id)
    fail_task(task, error_message)
    broadcast(:task, task.id, {:task_failed, error_message})
    broadcast(:pipeline, {:pipeline_idle, task.id})

    idle_state = return_idle(state)
    send(self(), {:continue, :check_queue})
    idle_state
  end

  defp mark_subtask_failed(subtasks, field, value, error_message) do
    case Enum.find(subtasks, &(Map.get(&1, field) == value)) do
      nil -> :ok
      subtask -> Plans.update_subtask(subtask, %{status: "failed", last_error: error_message})
    end
  end

  # --- Retry failed task ---

  defp do_retry_task(task, state) do
    Logger.info("Retrying failed task", task_id: task.id)

    config = state.config

    # Reset the task to executing (failed -> executing is a valid transition for retry)
    with {:ok, task} <- Tasks.update_task_status(task, "executing"),
         {:ok, workspace} <- resolve_workspace(config, task.id) do
      broadcast(:pipeline, {:pipeline_started, task.id})
      reset_failed_subtasks(task.id)

      state = %{
        state
        | status: :processing,
          current_task_id: task.id,
          current_step: :executing_subtask,
          workspace: workspace,
          paused: false
      }

      broadcast(:task, task.id, {:task_step, :executing_subtask})
      send(self(), {:continue, :execute_next_subtask})
      state
    else
      {:error, reason} ->
        Logger.error("Failed to retry task", task_id: task.id, reason: inspect(reason))
        state
    end
  end

  defp reset_failed_subtasks(task_id) do
    plan = Plans.get_plan_by_task_id(task_id)

    if plan do
      plan.subtasks
      |> Enum.filter(&(&1.status == "failed"))
      |> Enum.each(fn subtask ->
        Plans.reset_subtask_for_retry(subtask, nil)
      end)

      Plans.update_plan_status(plan, "executing")
    end
  end

  # --- Helpers ---

  defp resolve_workspace(%{workspace_root: nil}, _task_id), do: {:error, :no_workspace_root}

  defp resolve_workspace(config, task_id) do
    workspace_path = Workspace.workspace_path(config.workspace_root, task_id) |> Path.expand()

    if File.dir?(workspace_path) do
      {:ok, workspace_path}
    else
      {:error, :workspace_not_found}
    end
  end

  defp ensure_workspace(config, task_id) do
    if Workspace.exists?(config.workspace_root, task_id) do
      {:ok, Workspace.workspace_path(config.workspace_root, task_id) |> Path.expand()}
    else
      with {:ok, ws} <- Workspace.create(config.workspace_root, task_id),
           {:ok, _} <- Workspace.clone_repo(config.repo_path, ws) do
        {:ok, ws}
      end
    end
  end

  defp create_subtask_branch(workspace, task_id, subtask, plan) do
    branch = GitOps.branch_name(task_id, subtask.position, subtask.title)
    base = find_base_branch(subtask, plan)

    result =
      case base do
        "main" ->
          with :ok <- GitOps.checkout_main(workspace),
               :ok <- GitOps.create_branch(workspace, branch),
               do: :ok

        prev_branch ->
          GitOps.create_stacked_branch(workspace, prev_branch, branch)
      end

    case result do
      :ok -> {:ok, branch}
      error -> error
    end
  end

  defp find_base_branch(subtask, _plan) when subtask.position == 1, do: "main"

  defp find_base_branch(subtask, plan) do
    prev =
      plan.subtasks
      |> Enum.sort_by(& &1.position)
      |> Enum.find(&(&1.position == subtask.position - 1))

    case prev do
      nil -> "main"
      %{branch_name: nil} -> "main"
      %{branch_name: name} -> name
    end
  end

  defp build_subtask_prompt(subtask) do
    base = subtask.spec

    if subtask.last_error do
      """
      #{base}

      IMPORTANT: A previous attempt at this task failed. Here is the error context:
      #{subtask.last_error}

      Please address these issues in your implementation.
      """
    else
      base
    end
  end

  defp pr_base_branch(task_id, subtask) do
    if subtask.position == 1 do
      "main"
    else
      plan = Plans.get_plan_by_task_id(task_id)

      prev_subtask =
        plan.subtasks
        |> Enum.sort_by(& &1.position)
        |> Enum.find(&(&1.position == subtask.position - 1))

      case prev_subtask do
        nil -> "main"
        prev -> prev.branch_name || "main"
      end
    end
  end

  defp get_diff_for_review(workspace, base_branch, head_branch) do
    case GitOps.diff(workspace, base_branch, head_branch) do
      {:ok, diff} -> diff
      {:error, _} -> ""
    end
  end

  defp subtask_count(task_id) do
    plan = Plans.get_plan_by_task_id(task_id)
    if plan, do: length(plan.subtasks), else: 0
  end

  defp fail_task(task, error_message) do
    Logger.error("Task failed: #{error_message}", task_id: task.id)

    case Tasks.update_task_status(task, "failed") do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp cleanup_workspace(state) do
    if state.workspace && state.config.workspace_root do
      Workspace.cleanup(state.workspace, state.config.workspace_root)
    end
  rescue
    _ -> :ok
  end

  defp return_idle(state) do
    %{
      state
      | status: :idle,
        current_task_id: nil,
        current_subtask_id: nil,
        current_step: nil,
        workspace: nil,
        paused: false
    }
  end

  defp maybe_recover(state) do
    # Check for tasks in planning or executing state
    case find_in_progress_task() do
      nil ->
        state

      task ->
        Logger.info("Recovering in-progress task", task_id: task.id, status: task.status)
        recover_task(state, task)
    end
  end

  defp find_in_progress_task do
    ~w(executing planning plan_review)
    |> Enum.find_value(fn status ->
      case Tasks.list_tasks_by_status(status) do
        [task | _] -> task
        [] -> nil
      end
    end)
  end

  defp recover_task(state, task) do
    config = state.config
    workspace_path = Workspace.workspace_path(config.workspace_root, task.id) |> Path.expand()

    workspace =
      if File.dir?(workspace_path), do: workspace_path, else: nil

    paused = Settings.get_pipeline_paused()

    case task.status do
      "planning" ->
        %{
          state
          | status: :processing,
            current_task_id: task.id,
            current_step: :planning,
            workspace: workspace,
            paused: paused
        }

      "plan_review" ->
        %{
          state
          | status: :processing,
            current_task_id: task.id,
            current_step: :awaiting_plan_review,
            workspace: workspace,
            paused: paused
        }

      "executing" ->
        %{
          state
          | status: :processing,
            current_task_id: task.id,
            current_step: :executing_subtask,
            workspace: workspace,
            paused: paused
        }

      _ ->
        state
    end
  end

  defp broadcast(:pipeline, message) do
    Phoenix.PubSub.broadcast(SymphonyV2.PubSub, Topics.pipeline(), message)
  end

  defp broadcast(:task, task_id, message) do
    Phoenix.PubSub.broadcast(SymphonyV2.PubSub, Topics.task(task_id), message)
  end

  defp broadcast(:subtask, subtask_id, message) do
    Phoenix.PubSub.broadcast(SymphonyV2.PubSub, Topics.subtask(subtask_id), message)
  end

  defp persist_paused(value) do
    Settings.set_pipeline_paused(value)
  rescue
    error ->
      Logger.warning("Failed to persist pipeline paused state",
        paused: value,
        error: inspect(error)
      )
  end

  defp schedule_recovery_continuation(%{paused: true} = state) do
    Logger.info("Recovered task but pipeline is paused — waiting for resume",
      task_id: state.current_task_id,
      step: state.current_step
    )
  end

  defp schedule_recovery_continuation(state) do
    case state.current_step do
      :executing_subtask ->
        send(self(), {:continue, :execute_next_subtask})

      :planning ->
        # Re-planning will be triggered when the task is picked up
        Logger.info("Recovered planning task — will resume on next queue check",
          task_id: state.current_task_id
        )

      :awaiting_plan_review ->
        # Waiting for human input — no action needed
        Logger.info("Recovered task awaiting plan review",
          task_id: state.current_task_id
        )

      _ ->
        :ok
    end
  end

  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string
  defp truncate(string, max_length), do: String.slice(string, 0, max_length) <> "..."
end
