# Symphony v2 — Gap Fixes Implementation Plan

Addresses all 36 gaps identified in the architecture/code gap analysis.
Organized into 10 phases, ordered by dependency and severity.

---

## Phase 1: Subtask State Machine & ExecutionPlan Status Alignment ✅ DONE

**Gaps addressed:** #3 (ExecutionPlan missing "plan_review"), #4 (no formal subtask state machine), #10 (no subtask transition validation), #13 (no formal subtask state machine — design debt)

### Step 1.1 — Create `SubtaskState` module

Create `lib/symphony_v2/plans/subtask_state.ex` mirroring `TaskState`:

```elixir
defmodule SymphonyV2.Plans.SubtaskState do
  @moduledoc "Formal state machine for subtask status transitions."

  @transitions %{
    "pending"    => ["dispatched"],
    "dispatched" => ["running", "failed"],
    "running"    => ["testing", "failed"],
    "testing"    => ["in_review", "failed"],
    "in_review"  => ["succeeded", "failed", "pending"],  # pending = retry
    "succeeded"  => ["pending"],                          # retry on task-level retry
    "failed"     => ["pending"]                           # retry
  }

  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @spec valid_next_statuses(String.t()) :: [String.t()]
  def valid_next_statuses(status), do: Map.get(@transitions, status, [])

  @spec transitions() :: map()
  def transitions, do: @transitions
end
```

### Step 1.2 — Enforce transitions in `Plans` context

In `lib/symphony_v2/plans.ex`, modify `update_subtask_status/2` to validate:

```elixir
def update_subtask_status(subtask, new_status) do
  if SubtaskState.valid_transition?(subtask.status, new_status) do
    subtask |> Subtask.status_changeset(%{status: new_status}) |> Repo.update()
  else
    {:error, {:invalid_transition, subtask.status, new_status}}
  end
end
```

Also add a `reset_subtask_for_retry/2` function that explicitly allows the `succeeded/failed → pending` transition with field clearing, replacing the ad-hoc `update_subtask` calls in `pipeline.ex`.

### Step 1.3 — Add "plan_review" to ExecutionPlan statuses

In `lib/symphony_v2/plans/execution_plan.ex`, change:

```elixir
@statuses ~w(planning awaiting_review plan_review executing completed failed)
```

### Step 1.4 — Migration: Add check constraint for execution_plan status

Create migration to add a DB-level check constraint including `plan_review`:

```elixir
execute "ALTER TABLE execution_plans DROP CONSTRAINT IF EXISTS execution_plans_status_check"
execute """
ALTER TABLE execution_plans ADD CONSTRAINT execution_plans_status_check
CHECK (status IN ('planning', 'awaiting_review', 'plan_review', 'executing', 'completed', 'failed'))
"""
```

### Step 1.5 — Tests

- Unit tests for `SubtaskState`: all transitions, invalid transitions, boundary cases
- Update `Plans` context tests: verify `update_subtask_status/2` rejects invalid transitions
- Update pipeline tests: verify subtask transitions follow the state machine
- Test `reset_subtask_for_retry/2` function

**Files changed:** `plans/subtask_state.ex` (new), `plans/execution_plan.ex`, `plans.ex`, new migration, tests

---

## Phase 2: Pipeline State Transition Fixes ✅ DONE

**Gaps addressed:** #1 (planning failure doesn't update task status), #2 (missing planning → plan_review transition), #5 (review failure auto-approves), #7 (inconsistent error paths), #12 (merge failure doesn't mark subtasks failed)

### Step 2.1 — Fix `finish_failed/1` to update task status

In `pipeline.ex`, replace `finish_failed/1` with a call to `fail_current_task/2`:

```elixir
# BEFORE (line 822):
defp finish_failed(state) do
  broadcast(:pipeline, {:pipeline_idle, state.current_task_id})
  idle_state = return_idle(state)
  send(self(), {:continue, :check_queue})
  idle_state
end

# AFTER:
# Remove finish_failed entirely. Replace all call sites:
# - do_run_planning error path (line 323): call fail_current_task(state, reason)
# - do_approve_plan_for_task error path (line 356): call fail_current_task(state, reason)
# - do_reject_plan error path (line 370): call fail_current_task(state, reason)
```

Specifically in `do_run_planning/4` (line 320-324):

```elixir
{:error, reason} ->
  Logger.error("Planning failed", task_id: task.id, reason: inspect(reason))
  broadcast(:task, task.id, {:task_failed, reason})
  fail_current_task(state, "Planning failed: #{inspect(reason)}")
```

### Step 2.2 — Add task status transition to `plan_review` after planning

In `handle_planning_success/3` (line 327-336), transition both task and plan status:

```elixir
defp handle_planning_success(state, task, config) do
  if config.dangerously_skip_permissions do
    Logger.info("Auto-approving plan (dangerously_skip_permissions)", task_id: task.id)
    task = Tasks.get_task!(task.id)
    do_approve_plan_for_task(task, state)
  else
    # Transition task to plan_review
    task = Tasks.get_task!(task.id)
    plan = Plans.get_plan_by_task_id(task.id)

    with {:ok, _task} <- Tasks.update_task_status(task, "plan_review"),
         {:ok, _plan} <- Plans.update_plan_status(plan, "plan_review") do
      broadcast(:task, task.id, {:task_step, :awaiting_plan_review})
      %{state | current_step: :awaiting_plan_review}
    else
      {:error, reason} ->
        Logger.error("Failed to transition to plan_review", task_id: task.id, reason: inspect(reason))
        fail_current_task(state, "Failed to enter plan review: #{inspect(reason)}")
    end
  end
end
```

### Step 2.3 — Make review failure behavior configurable

Add `review_failure_action` to `AppConfig` (values: `:auto_approve` | `:fail`):

In `pipeline.ex` `run_review/2` error path (line 632-648):

```elixir
{:error, reason} ->
  case state.config.review_failure_action do
    :fail ->
      handle_subtask_failure(state, subtask, "Review failed: #{inspect(reason)}")

    :auto_approve ->
      Logger.warning("Review failed, auto-approving subtask", ...)
      {:ok, _subtask} = Plans.update_subtask(subtask, %{
        status: "succeeded",
        review_verdict: "skipped",
        review_reasoning: "Review failed: #{inspect(reason)}"
      })
      broadcast(:subtask, subtask.id, {:subtask_succeeded, subtask.position})
      advance_to_next_subtask(state)
  end
```

Default to `:auto_approve` to preserve existing behavior. Add the field to `AppConfig`, `AppSetting` schema, `SettingsLive`, and the migration.

### Step 2.4 — Fix merge failure to mark subtasks appropriately

In `do_merge/1`, when merge fails, mark the last subtask as failed so retry logic picks it up:

```elixir
{:error, {:merge_failed_at, number, reason}} ->
  Logger.error("Merge failed", pr_number: number, reason: inspect(reason))
  # Find the subtask with this PR number and mark it failed
  plan = Plans.get_plan_by_task_id(task.id)
  failed_subtask = Enum.find(plan.subtasks, &(&1.pr_number == number))
  if failed_subtask do
    Plans.update_subtask(failed_subtask, %{status: "failed", last_error: "Merge failed: #{inspect(reason)}"})
  end
  fail_current_task(state, "Merge failed at PR ##{number}: #{inspect(reason)}")
```

Similarly for rebase conflict/failure paths.

### Step 2.5 — Tests

- Test planning failure transitions task to "failed"
- Test successful planning transitions task to "plan_review"
- Test review failure with `:fail` config causes subtask failure
- Test review failure with `:auto_approve` config auto-approves (existing behavior)
- Test merge failure marks subtask as failed
- Test retry after merge failure resets the correct subtask
- Verify `finish_failed` is removed and all callers use `fail_current_task`

**Files changed:** `pipeline.ex`, `app_config.ex`, `settings/app_setting.ex`, `settings_live.ex`, new migration, tests

---

## Phase 3: Pause/Resume & Recovery Fixes ✅ DONE

**Gaps addressed:** #10 (pause only works during subtask execution), #11 (pause state lost on recovery), #13 (dead code handle_info DOWN)

### Step 3.1 — Expand resume to all pipeline steps

In `handle_cast(:resume, ...)` (line 179-192), add continuation for all steps:

```elixir
def handle_cast(:resume, %{paused: true} = state) do
  Logger.info("Pipeline resumed", task_id: state.current_task_id)
  broadcast(:pipeline, {:pipeline_resumed, state.current_task_id})
  state = %{state | paused: false}

  if state.status == :processing do
    case state.current_step do
      :executing_subtask ->
        send(self(), {:continue, :execute_next_subtask})

      :planning ->
        task = Tasks.get_task!(state.current_task_id)
        send(self(), {:continue, {:run_planning, task}})

      # Steps that are waiting for human input don't need a continue message.
      # They will proceed when the user takes action (approve/reject).
      :awaiting_plan_review -> :ok
      :awaiting_final_review -> :ok

      # Active steps (testing, reviewing) are already running in a receive block.
      # They don't need a continue — they'll complete and check paused state.
      _ -> :ok
    end
  end

  {:noreply, state}
end
```

Also add pause checks in `run_tests/2` and `run_review/2` entry points (bail early if paused).

### Step 3.2 — Add `{:continue, {:run_planning, task}}` handler

Add a new `handle_info` clause for the planning continuation:

```elixir
def handle_info({:continue, {:run_planning, task}}, state) do
  {:noreply, run_planning(state, task)}
end
```

### Step 3.3 — Persist pause state for recovery

Add `paused` field to pipeline recovery. Since Pipeline is in-memory, the simplest approach is to persist the pause flag in a lightweight mechanism:

Option A (recommended): Store `paused` in `app_settings` table as a boolean column.
Option B: Store in a dedicated `pipeline_state` table with a single row.

On recovery in `recover_task/2`, read the persisted pause flag:

```elixir
defp recover_task(state, task) do
  # ... existing code ...
  paused = Settings.get_pipeline_paused()

  case task.status do
    "planning" ->
      recovered = %{state | status: :processing, current_task_id: task.id,
                     current_step: :planning, workspace: workspace, paused: paused}
      if not paused, do: schedule_recovery_continuation(recovered)
      recovered
    # ... similar for other states ...
  end
end
```

Update `handle_cast(:pause, ...)` and `handle_cast(:resume, ...)` to persist the flag.

### Step 3.4 — Remove dead `handle_info({:DOWN, ...})` clause

Remove the unreachable handler at line 275-280. The `:DOWN` message is handled inside the `receive` block in `run_agent_and_handle_result/4`. Add a code comment explaining why.

### Step 3.5 — Tests

- Test pause during `awaiting_plan_review` → resume sends no continuation (waits for human)
- Test pause during `planning` → resume sends `{:continue, {:run_planning, task}}`
- Test pipeline crash + recovery preserves paused state
- Test pipeline crash + recovery with `paused: false` resumes execution
- Verify dead code handler is removed without regression

**Files changed:** `pipeline.ex`, `settings.ex`, `settings/app_setting.ex`, new migration (add `pipeline_paused` column), tests

---

## Phase 4: Workspace & Cleanup Fixes ✅ DONE

**Gaps addressed:** #7 (workspace cleanup only on success), #14 (cleanup errors silently swallowed), #19 (cleanup errors silently swallowed)

### Step 4.1 — Add workspace cleanup on task failure

In `fail_current_task/2` (line 811-820), add cleanup:

```elixir
defp fail_current_task(state, error_message) do
  task = Tasks.get_task!(state.current_task_id)
  fail_task(task, error_message)
  broadcast(:task, task.id, {:task_failed, error_message})
  broadcast(:pipeline, {:pipeline_idle, task.id})

  # Cleanup workspace on failure too
  cleanup_workspace(state)

  idle_state = return_idle(state)
  send(self(), {:continue, :check_queue})
  idle_state
end
```

### Step 4.2 — Log cleanup errors instead of silently swallowing

In `cleanup_workspace/1` (line 1000-1006):

```elixir
defp cleanup_workspace(state) do
  if state.workspace && state.config && state.config.workspace_root do
    case Workspace.cleanup(state.workspace, state.config.workspace_root) do
      :ok -> Logger.info("Workspace cleaned up", workspace: state.workspace)
      {:error, reason} -> Logger.warning("Workspace cleanup failed", workspace: state.workspace, reason: inspect(reason))
    end
  end
rescue
  error ->
    Logger.warning("Workspace cleanup raised", workspace: state.workspace, error: inspect(error))
end
```

### Step 4.3 — Make `Workspace.cleanup/2` return ok/error tuple

If `Workspace.cleanup/2` currently raises, change it to return `{:ok, :cleaned}` or `{:error, reason}`.

### Step 4.4 — Tests

- Test that failed task triggers workspace cleanup
- Test that cleanup errors are logged but don't crash the pipeline
- Test that `Workspace.cleanup/2` returns proper tuples

**Files changed:** `pipeline.ex`, `workspace.ex`, tests

---

## Phase 5: Data Integrity & Safety Fixes ✅ DONE

**Gaps addressed:** #8 (AppSetting singleton), #9 (atom exhaustion), #20 (agent run cascade delete), #21 (subtask editable while executing), #22 (String.to_atom in pipeline)

### Step 5.1 — Enforce AppSetting singleton at DB level

Create migration:

```elixir
# Add a singleton constraint column
execute """
ALTER TABLE app_settings ADD COLUMN singleton BOOLEAN DEFAULT true NOT NULL,
ADD CONSTRAINT app_settings_singleton UNIQUE (singleton),
ADD CONSTRAINT app_settings_singleton_true CHECK (singleton = true)
"""
```

Update `Settings.get_settings/0` to use `Repo.insert` with `on_conflict: :nothing`:

```elixir
def get_settings do
  case Repo.one(AppSetting) do
    nil ->
      %AppSetting{singleton: true}
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :singleton)
      Repo.one(AppSetting) || %AppSetting{}
    setting ->
      setting
  end
end
```

### Step 5.2 — Replace `String.to_atom` with safe alternatives

In `agent_registry.ex` line 149, replace:

```elixir
# BEFORE:
name: String.to_atom(ca.name)

# AFTER:
name: safe_to_atom(ca.name)

# Where safe_to_atom uses String.to_existing_atom with fallback:
defp safe_to_atom(name) when is_binary(name) do
  String.to_existing_atom(name)
rescue
  ArgumentError -> String.to_atom(name)
end
```

Better: validate custom agent names against an allowlist pattern and cap the total number of custom agents (e.g., 50). Add validation in `CustomAgent` changeset:

```elixir
|> validate_length(:name, max: 50)
|> validate_format(:name, ~r/^[a-z][a-z0-9_]{0,49}$/)
```

In `pipeline.ex` line ~434 (where `String.to_atom(subtask.agent_type)` is called):

```elixir
# BEFORE:
agent_type = String.to_atom(subtask.agent_type)

# AFTER:
agent_type = AgentRegistry.normalize_agent_type(subtask.agent_type)
```

Add `AgentRegistry.normalize_agent_type/1` that returns an atom only if the agent is registered, otherwise `{:error, :unknown_agent}`.

### Step 5.3 — Add subtask edit guard

In `Plans.update_subtask_plan_fields/2`, add status check:

```elixir
def update_subtask_plan_fields(subtask, attrs) do
  if subtask.status in ["pending", "failed"] do
    subtask |> Subtask.edit_changeset(attrs) |> Repo.update()
  else
    {:error, :subtask_not_editable}
  end
end
```

### Step 5.4 — Soft-delete agent runs or prevent cascade

Option A (soft delete): Add `deleted_at` to agent_runs, change cascade to `:nilify_all`.
Option B (recommended, simpler): Change the migration to `on_delete: :nilify_all` so deleting a subtask sets `subtask_id` to nil on agent_runs rather than deleting them. Add a `deleted_subtask_id` field for audit trail.

Actually simplest: just change `on_delete: :delete_all` to `on_delete: :nothing` and handle cleanup explicitly, or accept the cascade but archive runs first.

Recommended approach — archive before delete:

```elixir
def delete_subtask(subtask) do
  # Agent runs are cascade-deleted, but we log a warning
  run_count = Repo.aggregate(from(r in AgentRun, where: r.subtask_id == ^subtask.id), :count)
  if run_count > 0 do
    Logger.info("Deleting subtask with #{run_count} agent runs", subtask_id: subtask.id)
  end

  Repo.delete(subtask)
  |> tap(fn _ -> resequence_positions(subtask.execution_plan_id) end)
end
```

For a more robust solution, change the FK to `on_delete: :nilify_all` via migration so agent runs survive subtask deletion.

### Step 5.5 — Tests

- Test AppSetting singleton constraint (concurrent inserts)
- Test custom agent name length/format validation
- Test `normalize_agent_type` returns error for unknown agent
- Test subtask edit rejected when status is "running", "testing", etc.
- Test subtask deletion with agent runs (verify behavior)

**Files changed:** `settings.ex`, `settings/app_setting.ex`, `settings/custom_agent.ex`, `agent_registry.ex`, `pipeline.ex`, `plans.ex`, new migration, tests

---

## Phase 6: External Tool Validation & Error Handling

**Gaps addressed:** #6 (gh CLI PR URL crash), #15 (zombie subprocess leak), #16 (IO.write not guarded), #17 (safehouse not validated), #18 (rebase abort ignored), #36 (TestRunner shell_command nil)

### Step 6.1 — Safe PR URL parsing in `GitHub.create_pr/2`

In `git_ops/github.ex` (line 26-27):

```elixir
# BEFORE:
number = url |> String.split("/") |> List.last() |> String.to_integer()

# AFTER:
case Integer.parse(url |> String.split("/") |> List.last()) do
  {number, _} ->
    {:ok, %{url: url, number: number}}
  :error ->
    Logger.error("Could not parse PR number from gh output", output: url)
    {:error, {:pr_parse_failed, url}}
end
```

### Step 6.2 — Kill process group instead of single PID

In `agent_process.ex` `kill_port/1`:

```elixir
defp kill_port(port) do
  case Port.info(port, :os_pid) do
    {:os_pid, os_pid} ->
      # Kill the entire process group to catch child processes
      System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
    nil ->
      :ok
  end

  try do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
```

Note: `kill -9 -<pgid>` sends SIGKILL to the process group. On macOS, the child processes launched via Port typically share the parent's PGID.

### Step 6.3 — Guard IO.write in agent output handler

In `agent_process.ex` `handle_info({port, {:data, data}}, ...)`:

```elixir
def handle_info({port, {:data, data}}, %{port: port} = state) do
  text = IO.iodata_to_binary(data)

  # Write to log file (non-fatal on failure)
  try do
    IO.write(state.log_file, text)
  rescue
    _ -> Logger.warning("Failed to write agent output to log file", agent_run_id: state.agent_run_id)
  end

  Phoenix.PubSub.broadcast(SymphonyV2.PubSub, Topics.agent_output(state.agent_run_id), {:agent_output, text})
  {:noreply, %{state | output: [text | state.output]}}
end
```

### Step 6.4 — Validate safehouse binary existence

In `safehouse.ex` `build_command/3`, add a check:

```elixir
def build_command(agent_type, workspace_path, opts \\ []) do
  with :ok <- validate_safehouse_available(),
       :ok <- validate_path(workspace_path),
       {:ok, agent} <- fetch_agent(agent_type) do
    # ... existing command building ...
  end
end

defp validate_safehouse_available do
  if System.find_executable(@safehouse_command) do
    :ok
  else
    {:error, {:safehouse_not_found, "#{@safehouse_command} binary not found in PATH"}}
  end
end
```

### Step 6.5 — Handle rebase abort failure

In `git_ops.ex` `rebase_onto/2`:

```elixir
def rebase_onto(workspace, target) do
  case git(workspace, ["rebase", target]) do
    {:ok, _} ->
      :ok

    {:error, {:git_failed, _code, _output}} ->
      case git(workspace, ["rebase", "--abort"]) do
        {:ok, _} -> :ok
        {:error, abort_err} ->
          Logger.error("Failed to abort rebase", workspace: workspace, error: inspect(abort_err))
      end
      {:error, :conflict}
  end
end
```

### Step 6.6 — Validate shell executable in TestRunner

In `test_runner.ex` `shell_command/0`:

```elixir
defp shell_command do
  {exe, flag} =
    case :os.type() do
      {:unix, _} -> {"sh", "-c"}
      {:win32, _} -> {"cmd", "/c"}
    end

  case System.find_executable(exe) do
    nil -> {:error, {:shell_not_found, exe}}
    path -> {:ok, {path, flag}}
  end
end
```

Update `run/3` to handle the error tuple from `shell_command/0`.

### Step 6.7 — Tests

- Test PR creation with malformed gh output (no crash)
- Test agent process IO.write failure doesn't crash GenServer
- Test safehouse build_command when binary doesn't exist
- Test rebase abort failure is logged
- Test shell_command returns error when executable missing
- Test kill_port with process group

**Files changed:** `git_ops/github.ex`, `agent_process.ex`, `safehouse.ex`, `git_ops.ex`, `test_runner.ex`, tests

---

## Phase 7: LiveView PubSub & Real-Time Fixes

**Gaps addressed:** #24 (incomplete PubSub subscriptions), #26 (stale data in handlers), #27 (TaskLive.Index missing subscriptions), #29 (external PR merge not detected)

### Step 7.1 — Subscribe TaskLive.Show to subtask topics

In `task_live/show.ex` mount, after loading the plan:

```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))

  # Subscribe to all subtask topics for real-time updates
  if plan do
    Enum.each(plan.subtasks, fn subtask ->
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.subtask(subtask.id))
    end)
  end
end
```

Add `handle_info` for subtask events:

```elixir
def handle_info({:subtask_succeeded, _pos}, socket), do: {:noreply, reload_data(socket)}
def handle_info({:subtask_failed, _pos, _err}, socket), do: {:noreply, reload_data(socket)}
def handle_info({:subtask_testing, _pos}, socket), do: {:noreply, reload_data(socket)}
def handle_info({:subtask_retrying, _pos, _count}, socket), do: {:noreply, reload_data(socket)}
# Catch-all for other subtask events
def handle_info({event, _}, socket) when event in [:subtask_started, :subtask_running], do: {:noreply, reload_data(socket)}
```

### Step 7.2 — Subscribe PlanLive.Show to subtask topics

Same pattern as Step 7.1. Also subscribe to new subtasks when they're added:

```elixir
def handle_event("add_subtask", ...) do
  # ... existing add logic ...
  # Subscribe to the new subtask's topic
  if new_subtask do
    Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.subtask(new_subtask.id))
  end
end
```

### Step 7.3 — Subscribe TaskLive.Index to task-level updates

In `task_live/index.ex` mount:

```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.pipeline())
  # Subscribe to a general "tasks" topic for any task status change
end
```

Add a new topic `Topics.tasks()` that returns `"tasks"`. Broadcast to it from `Tasks.update_task_status/2`:

```elixir
# In Tasks context, after successful status update:
Phoenix.PubSub.broadcast(SymphonyV2.PubSub, "tasks", {:task_status_changed, task.id, new_status})
```

Handle in TaskLive.Index:

```elixir
def handle_info({:task_status_changed, _task_id, _status}, socket) do
  {:noreply, assign(socket, :tasks, load_tasks(socket.assigns.filter))}
end
```

### Step 7.4 — Re-fetch data in event handlers before acting

In `TaskLive.Show`, `PlanLive.Show`, and `StackReviewLive`, add re-fetch before critical actions:

```elixir
# TaskLive.Show approve_plan handler
def handle_event("approve_plan", _, socket) do
  # Re-fetch task to check current status
  task = Tasks.get_task!(socket.assigns.task.id)

  if task.status == "plan_review" do
    case Pipeline.approve_plan() do
      :ok -> {:noreply, reload_data(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_pipeline_error(reason))}
    end
  else
    {:noreply, socket |> put_flash(:error, "Task is no longer awaiting plan review.") |> reload_data()}
  end
end
```

### Step 7.5 — Add human-readable error messages

Create a helper module `SymphonyV2Web.PipelineErrors`:

```elixir
defmodule SymphonyV2Web.PipelineErrors do
  def format(:not_awaiting_plan_review), do: "This task is no longer awaiting plan review. The page has been refreshed."
  def format(:not_awaiting_final_review), do: "This task is no longer awaiting final review. The page has been refreshed."
  def format({:invalid_transition, from, to}), do: "Cannot move task from #{from} to #{to}."
  def format(reason), do: "Operation failed: #{inspect(reason)}"
end
```

Use it in all LiveView error flash messages.

### Step 7.6 — Tests

- Test TaskLive.Show receives and handles subtask PubSub events
- Test PlanLive.Show receives subtask updates
- Test TaskLive.Index refreshes on task_status_changed events
- Test stale data handling (approve already-approved task shows error)
- Test human-readable error messages

**Files changed:** `task_live/show.ex`, `task_live/index.ex`, `plan_live/show.ex`, `stack_review_live.ex`, `dashboard_live.ex`, `pubsub/topics.ex`, `tasks.ex`, `pipeline_errors.ex` (new), tests

---

## Phase 8: Concurrent Edit Protection & UI Scaling

**Gaps addressed:** #25 (concurrent plan editing), #28 (dashboard unbounded lists), #30 (review_verdict/reasoning consistency)

### Step 8.1 — Add optimistic locking to Subtask

Add `lock_version` to subtask schema and migration:

```elixir
# Migration
alter table(:subtasks) do
  add :lock_version, :integer, default: 1
end

# Schema
field :lock_version, :integer, default: 1
```

Update `Subtask.edit_changeset/2` to use `optimistic_lock(:lock_version)`:

```elixir
def edit_changeset(subtask, attrs) do
  subtask
  |> cast(attrs, [:title, :spec, :agent_type])
  |> validate_required([:title, :spec, :agent_type])
  |> validate_inclusion(:agent_type, @agent_types)
  |> optimistic_lock(:lock_version)
end
```

In `PlanLive.Show`, catch `Ecto.StaleEntryError`:

```elixir
def handle_event("save_subtask", params, socket) do
  case Plans.update_subtask_plan_fields(subtask, params) do
    {:ok, _} -> {:noreply, reload_task(socket)}
    {:error, :subtask_not_editable} -> {:noreply, put_flash(socket, :error, "This subtask can no longer be edited.")}
    {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, :changeset, cs)}
  end
rescue
  Ecto.StaleEntryError ->
    {:noreply, socket |> put_flash(:error, "This subtask was modified by another user. Refreshing.") |> reload_task()}
end
```

### Step 8.2 — Add pagination to Dashboard subtask list

In `DashboardLive`, limit the number of visible subtasks and add "show more" toggle:

```elixir
# In assigns, add:
assign(socket, :subtask_display_limit, 20)

# In template, limit displayed subtasks:
<%= for subtask <- Enum.take(@subtasks, @subtask_display_limit) do %>
  ...
<% end %>
<%= if length(@subtasks) > @subtask_display_limit do %>
  <button phx-click="show_all_subtasks" class="btn btn-sm btn-ghost">
    Show all <%= length(@subtasks) %> subtasks
  </button>
<% end %>
```

Similarly for the task queue sidebar.

### Step 8.3 — Validate review_verdict / review_reasoning consistency

In `Subtask.update_changeset/2`, add a custom validation:

```elixir
|> validate_review_consistency()

defp validate_review_consistency(changeset) do
  verdict = get_field(changeset, :review_verdict)
  reasoning = get_field(changeset, :review_reasoning)

  case {verdict, reasoning} do
    {"rejected", nil} -> add_error(changeset, :review_reasoning, "is required when verdict is rejected")
    {"rejected", ""} -> add_error(changeset, :review_reasoning, "is required when verdict is rejected")
    _ -> changeset
  end
end
```

### Step 8.4 — Tests

- Test optimistic locking detects concurrent edits
- Test PlanLive.Show handles StaleEntryError gracefully
- Test dashboard with 50+ subtasks (pagination)
- Test review_verdict "rejected" requires non-empty reasoning

**Files changed:** `plans/subtask.ex`, `plan_live/show.ex`, `dashboard_live.ex`, new migration, tests

---

## Phase 9: Config & Validation Hardening

**Gaps addressed:** #31 (queue_position not validated), #32 (position gaps when adding subtasks), #34 (relevant_files not validated), #35 (AppConfig silent errors)

### Step 9.1 — Validate queue_position

In `Task.queue_changeset/2`:

```elixir
def queue_changeset(task, attrs) do
  task
  |> cast(attrs, [:queue_position])
  |> validate_number(:queue_position, greater_than_or_equal_to: 0)
end
```

### Step 9.2 — Fix position gaps in `add_subtask_to_plan/2`

In `Plans.add_subtask_to_plan/2`, clamp the position to be within valid range:

```elixir
def add_subtask_to_plan(plan, attrs) do
  max_position = length(plan.subtasks)
  requested_position = Map.get(attrs, :position, max_position + 1)
  # Clamp to valid range [1, max_position + 1]
  clamped_position = max(1, min(requested_position, max_position + 1))
  attrs = Map.put(attrs, :position, clamped_position)

  # ... existing insert + resequence logic ...
end
```

### Step 9.3 — Add length validation to relevant_files

In `Task.create_changeset/2`:

```elixir
|> validate_length(:relevant_files, max: 10_000, message: "is too long (max 10,000 characters)")
```

### Step 9.4 — Validate AppConfig at startup

In `application.ex`, add a startup check:

```elixir
def start(_type, _args) do
  children = [...]

  opts = [strategy: :one_for_one, name: SymphonyV2.Supervisor]
  result = Supervisor.start_link(children, opts)

  # Validate config after repo is started
  case AppConfig.load_and_validate() do
    {:ok, _config} -> :ok
    {:error, errors} ->
      Logger.warning("AppConfig validation warnings at startup: #{inspect(errors)}")
  end

  result
end
```

Make `AppConfig.load/0` log warnings for missing values instead of silently returning nil:

```elixir
defp merge_db_settings(base) do
  case db_settings() do
    nil ->
      Logger.debug("No DB settings found, using defaults")
      base
    setting ->
      apply_db_overrides(base, setting)
  end
rescue
  error ->
    Logger.warning("Failed to load DB settings, using defaults", error: inspect(error))
    base
end
```

### Step 9.5 — Tests

- Test queue_position rejects negative values
- Test add_subtask_to_plan clamps position
- Test relevant_files rejects > 10k characters
- Test AppConfig logs warnings for missing values

**Files changed:** `tasks/task.ex`, `plans.ex`, `app_config.ex`, `application.ex`, tests

---

## Phase 10: Minor Fixes & Cleanup

**Gaps addressed:** #33 (orphaned planning subtasks), #23 (missing composite index), #14 (pipeline task completion re-check)

### Step 10.1 — Fix planning subtask cleanup

In `planning_agent.ex`, ensure cleanup runs even on error paths:

```elixir
def run(task, workspace, opts \\ []) do
  with {:ok, agent_run} <- create_agent_run(task, agent_type),
       plan = Plans.get_plan_by_task_id(task.id),
       {:ok, result} <- launch_agent(...),
       :ok <- check_agent_success(result),
       {:ok, subtask_entries} <- parse_plan(workspace) do
    cleanup_planning_subtasks(plan)
    create_real_subtasks(plan, subtask_entries)
  else
    error ->
      # Always cleanup temp planning subtasks
      plan = Plans.get_plan_by_task_id(task.id)
      if plan, do: cleanup_planning_subtasks(plan)
      error
  end
end
```

### Step 10.2 — Add composite index

Create migration:

```elixir
create index(:tasks, [:status, :queue_position])
```

### Step 10.3 — Add atomic completion check

In `complete_task/1`, re-verify subtask status in a transaction:

```elixir
defp complete_task(state) do
  task = Tasks.get_task!(state.current_task_id)
  plan = Plans.get_plan_by_task_id(task.id)

  # Re-verify all subtasks succeeded
  unless Plans.all_subtasks_succeeded?(plan) do
    Logger.error("Cannot complete task: not all subtasks succeeded", task_id: task.id)
    return fail_current_task(state, "Not all subtasks succeeded")
  end

  case Tasks.update_task_status(task, "completed") do
    # ... existing code ...
  end
end
```

### Step 10.4 — Remove hardcoded timeout grace period

In `run_agent_and_handle_result/4`, make the grace period configurable or remove it:

```elixir
# The agent process handles its own timeout internally.
# The pipeline's receive timeout is a safety net.
@pipeline_timeout_buffer_ms 10_000

# In receive:
after
  timeout_ms + @pipeline_timeout_buffer_ms ->
    Logger.warning("Pipeline safety timeout triggered", subtask_id: subtask.id)
    handle_agent_complete(state, subtask, %{status: :timeout})
end
```

Extract to a module attribute for clarity.

### Step 10.5 — Tests

- Test planning subtask cleanup on error paths
- Test composite index doesn't change behavior (existing query tests still pass)
- Test `complete_task` with a subtask that sneaked back to failed

**Files changed:** `planning_agent.ex`, `pipeline.ex`, new migration, tests

---

## Summary Table

| Phase | Gaps Fixed | New Files | Modified Files | Migrations | Est. Tests |
|-------|-----------|-----------|----------------|------------|------------|
| 1 | #3, #4, #10, #13 | `subtask_state.ex` | `execution_plan.ex`, `plans.ex` | 1 | ~20 |
| 2 | #1, #2, #5, #7, #12 | — | `pipeline.ex`, `app_config.ex`, `app_setting.ex`, `settings_live.ex` | 1 | ~25 |
| 3 | #10, #11, #13 | — | `pipeline.ex`, `settings.ex`, `app_setting.ex` | 1 | ~15 |
| 4 | #7, #14, #19 | — | `pipeline.ex`, `workspace.ex` | 0 | ~10 |
| 5 | #8, #9, #20, #21, #22 | — | `settings.ex`, `app_setting.ex`, `custom_agent.ex`, `agent_registry.ex`, `pipeline.ex`, `plans.ex` | 1 | ~20 |
| 6 | #6, #15, #16, #17, #18, #36 | — | `github.ex`, `agent_process.ex`, `safehouse.ex`, `git_ops.ex`, `test_runner.ex` | 0 | ~20 |
| 7 | #24, #26, #27, #29 | `pipeline_errors.ex` | `task_live/show.ex`, `task_live/index.ex`, `plan_live/show.ex`, `stack_review_live.ex`, `dashboard_live.ex`, `topics.ex`, `tasks.ex` | 0 | ~25 |
| 8 | #25, #28, #30 | — | `subtask.ex`, `plan_live/show.ex`, `dashboard_live.ex` | 1 | ~15 |
| 9 | #31, #32, #34, #35 | — | `task.ex`, `plans.ex`, `app_config.ex`, `application.ex` | 0 | ~12 |
| 10 | #23, #33, #14 | — | `planning_agent.ex`, `pipeline.ex` | 1 | ~10 |
| **Total** | **36 gaps** | **2 new** | **~25 modified** | **6 migrations** | **~172 tests** |

---

## Dependency Graph

```
Phase 1 (SubtaskState + ExecutionPlan alignment)
  ├─→ Phase 2 (Pipeline state transitions) — depends on Phase 1 for SubtaskState
  │     └─→ Phase 3 (Pause/Resume) — depends on Phase 2 for state fixes
  │           └─→ Phase 4 (Workspace cleanup) — depends on Phase 2 for fail_current_task changes
  │
  ├─→ Phase 5 (Data integrity) — depends on Phase 1 for subtask edit guard
  │
  └─→ Phase 8 (Optimistic locking) — depends on Phase 1 for subtask changes

Phase 6 (Tool validation) — independent, can run in parallel with Phases 1-5
Phase 7 (LiveView PubSub) — depends on Phase 2 for error format changes
Phase 9 (Config validation) — independent, can run in parallel
Phase 10 (Minor fixes) — depends on Phases 1-2 for state machine changes
```

**Parallel execution lanes:**
- Lane A: Phase 1 → 2 → 3 → 4
- Lane B: Phase 6 (independent)
- Lane C: Phase 9 (independent)
- Then: Phase 5, 7, 8, 10 (after Lane A completes)
