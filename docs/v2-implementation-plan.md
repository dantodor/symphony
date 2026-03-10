# Symphony v2 — Implementation Plan

Detailed step-by-step plan derived from the [design brainstorm](./v2-design-brainstorm.md). Each step is a discrete, implementable unit that produces something testable.

Reference: The new app lives in a new directory (e.g., `v2/`) alongside the existing `elixir/` directory. It is a fresh Phoenix app with Ecto/Postgres.

---

## Phase 1: Project Bootstrap (Steps 1–8) ✅ DONE

### Step 1: Generate new Phoenix app ✅
```bash
mix phx.new v2 --app symphony_v2 --module SymphonyV2
```
Generated Phoenix 1.8.5 app in `v2/` directory with Ecto, Postgrex, Phoenix LiveView.

### Step 2: Configure within the monorepo ✅
- App lives in `v2/` directory
- Symlinked `mise.toml` → `../elixir/mise.toml` for Erlang/Elixir versions

### Step 3: Configure development database ✅
- Default `config/dev.exs` already uses `symphony_v2_dev` database name
- Postgres credentials: postgres/postgres on localhost

### Step 4: Create database and verify boot ✅
- `mix ecto.create` succeeded
- Database `symphony_v2_dev` created

### Step 5: Set up Makefile ✅
- Created `v2/Makefile` with targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, dialyzer, ci, all

### Step 6: Add Credo and Dialyxir dependencies ✅
```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}
{:dialyxir, "~> 1.4", only: [:dev], runtime: false}
```
Added `lint` alias: `["credo --strict"]`

### Step 7: Configure formatter and Credo ✅
- `.formatter.exs` — Phoenix/Ecto plugins (generated default)
- `.credo.exs` — strict mode with full check suite

### Step 8: Verify full quality gate passes ✅
- 5 tests pass, 0 failures
- Formatter clean
- Credo strict: no issues
- Dialyzer: 0 errors
- Compile with `--warnings-as-errors`: clean

---

## Phase 2: Authentication (Steps 9–16) ✅ DONE

### Step 9: Run phx.gen.auth ✅
```bash
mix phx.gen.auth Accounts User users
```
Generated User schema, migrations, controller pages (register/login/settings), plugs, Accounts context.

### Step 10: Run auth migrations ✅
```bash
mix ecto.migrate
```

### Step 11: Verify auth flow in browser ✅
Registration, login, logout, protected routes all working.

### Step 12: Simplify auth — remove email confirmation ✅
- Switched to password-based registration (immediate login on register)
- Removed magic link login flow entirely
- Removed email confirmation/change flow
- Removed UserNotifier module (no emails needed)
- Cleaned up UserToken (session tokens only)
- Simplified login to email + password only

### Step 13: Create seed script ✅
`priv/repo/seeds.exs` — creates `admin@localhost` / `admin_password_123` for development. Idempotent (skips if exists).

### Step 14: Add `:require_authenticated_user` to all app routes ✅
Router updated: `/` and `/users/settings` behind auth. Only `/users/register`, `/users/log-in`, `/users/log-out` are public.

### Step 15: Verify seed and auth-protected routes ✅
`mix ecto.reset` — drop, create, migrate, seed all pass cleanly.

### Step 16: Write auth tests ✅
71 tests pass (0 failures). Coverage 94.38%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 3: Core Data Model — Tasks (Steps 17–27) ✅ DONE

### Step 17: Create tasks migration ✅
UUID primary key, all fields per spec. Indexes on creator_id, reviewer_id, status, queue_position.

### Step 18: Create Task Ecto schema ✅
`lib/symphony_v2/tasks/task.ex` — all fields, `belongs_to :creator/:reviewer` (User), changesets for create, status transition, review, and queue position.

### Step 19: Define task status enum ✅
Valid statuses: `draft`, `awaiting_review`, `planning`, `plan_review`, `executing`, `completed`, `failed`. Defined as module attribute with `validate_inclusion`.

### Step 20: Implement task state machine ✅
`lib/symphony_v2/tasks/task_state.ex` — transitions map with `valid_transition?/2` and `valid_next_statuses/1`. All transitions per spec implemented.

### Step 21: Create Tasks context module ✅
`lib/symphony_v2/tasks.ex` — public API: `create_task/2`, `list_tasks/0`, `list_tasks_by_status/1`, `get_task!/1`, `update_task_status/2`, `approve_task_review/2` (self-review prevention via Multi), `next_queued_task/0`.

### Step 22: Write unit tests for Task schema ✅
`test/symphony_v2/tasks/task_test.exs` — changeset validations for required fields, title length, status enum, defaults, review_requested, relevant_files.

### Step 23: Write unit tests for task state transitions ✅
`test/symphony_v2/tasks/task_state_test.exs` — all valid transitions succeed, all invalid transitions rejected, terminal state (completed), unknown status handling.

### Step 24: Create execution_plans migration ✅
UUID primary key, task_id (unique), status, raw_plan (JSONB), plan_file_path. Indexes on task_id (unique) and status.

### Step 25: Create ExecutionPlan schema ✅
`lib/symphony_v2/plans/execution_plan.ex` — belongs_to task, has_many subtasks (ordered by position). Status enum: planning, awaiting_review, executing, completed, failed.

### Step 26: Create subtasks migration ✅
UUID primary key, all fields per spec. Unique index on (execution_plan_id, position). Indexes on execution_plan_id and status.

### Step 27: Create Subtask schema ✅
`lib/symphony_v2/plans/subtask.ex` — belongs_to execution_plan. Status enum: pending, dispatched, running, testing, in_review, succeeded, failed. Agent types: claude_code, codex, gemini_cli, opencode.

---

## Phase 4: Core Data Model — Agent Runs (Steps 28–33) ✅ DONE

### Step 28: Create agent_runs migration ✅
UUID primary key, all fields per spec. Indexes on subtask_id and status.

### Step 29: Create AgentRun schema ✅
`lib/symphony_v2/plans/agent_run.ex` — belongs_to subtask. Status: `running`, `succeeded`, `failed`, `timeout`. Changesets for create and complete.

### Step 30: Create Plans context module ✅
`lib/symphony_v2/plans.ex` — public API: `create_plan/1`, `get_plan!/1` (with subtask+agent_run preloads), `get_plan_by_task_id/1`, `update_plan_status/2`, `create_subtasks_from_plan/2` (transactional), `update_subtask/2`, `update_subtask_status/2`, `next_pending_subtask/1`, `all_subtasks_succeeded?/1`, `create_agent_run/1`, `complete_agent_run/2`.

### Step 31: Write unit tests for ExecutionPlan schema ✅
Already completed in Phase 3.

### Step 32: Write unit tests for Subtask schema and status transitions ✅
Already completed in Phase 3.

### Step 33: Write unit tests for Plans context operations ✅
`test/symphony_v2/plans_test.exs` and `test/symphony_v2/plans/agent_run_test.exs` — 181 tests total, 0 failures. Coverage 93.68%. Full quality gate passes.

---

## Phase 5: Application Configuration (Steps 34–41) ✅ DONE

### Step 34: Define AppConfig schema ✅
`lib/symphony_v2/app_config.ex` — typed struct for runtime configuration with defaults. Fields: repo_path, workspace_root, test_command, planning_agent, review_agent, default_agent, dangerously_skip_permissions, agent_timeout_ms, max_retries.

### Step 35: Load config from application env / config file ✅
`AppConfig.load/0` loads from `Application.get_env(:symphony_v2, SymphonyV2.AppConfig)`. Dev defaults configured in `config/dev.exs` with environment variable overrides for repo_path and workspace_root.

### Step 36: Create AgentRegistry module ✅
`lib/symphony_v2/agents/agent_registry.ex` — maps agent type atoms to CLI configurations via `AgentDef` struct. `lib/symphony_v2/agents/agent_def.ex` — typed struct with name, command, skip_permissions_flag, prompt_flag, env_vars.

### Step 37: Define agent configurations for each supported agent ✅
- Claude Code: `claude -p "<prompt>" --dangerously-skip-permissions` (env: ANTHROPIC_API_KEY)
- Codex: `codex -q "<prompt>" --dangerously-bypass-approvals-and-sandbox` (env: OPENAI_API_KEY)
- Gemini CLI: `gemini -p "<prompt>"` (env: GEMINI_API_KEY)
- Opencode: `opencode -p "<prompt>"`

### Step 38: Create config validation ✅
`AppConfig.validate/1` checks: repo_path exists as directory, workspace_root exists and is writable, all agent type references (planning, review, default) are registered, timeout is positive, max_retries is non-negative. `AppConfig.load_and_validate/0` combines load + validate.

### Step 39: Make agent registry extensible ✅
Custom agents added via application config: `config :symphony_v2, SymphonyV2.Agents.AgentRegistry, custom_agents: [%{name: ..., command: ..., prompt_flag: ...}]`. Invalid custom agent definitions are silently skipped.

### Step 40: Write unit tests for config loading and validation ✅
`test/symphony_v2/app_config_test.exs` — 14 tests covering struct defaults, load from env, defaults when no config, validation of all fields (repo_path, workspace_root, agent types, timeout, max_retries), error accumulation, load_and_validate.

### Step 41: Write unit tests for AgentRegistry (lookup, command building) ✅
`test/symphony_v2/agents/agent_registry_test.exs` — 22 tests covering all/get/registered?/agent_names/agent_type_strings/build_command/builtin_agents, per-agent definition verification, custom agents via config, invalid custom agent filtering. `test/symphony_v2/agents/agent_def_test.exs` — 8 tests covering AgentDef.new with keyword/map/string keys, required field validation.

---

## Phase 6: Safehouse Integration (Steps 42–48) ✅ DONE

### Step 42: Create Safehouse module ✅
`lib/symphony_v2/agents/safehouse.ex` — builds the full `safehouse` CLI command. Takes agent type, workspace path, and options. Returns `{:ok, {command, args}}` tuples using list-based args (no shell string concatenation).

### Step 43: Implement `build_command/3` ✅
```elixir
Safehouse.build_command(:claude_code, "/path/to/workspace", prompt: "Fix the bug")
# → {:ok, {"safehouse", ["--add-dirs=/path/to/workspace", "--env-pass=ANTHROPIC_API_KEY",
#     "--", "claude", "-p", "Fix the bug", "--dangerously-skip-permissions"]}}
```
Also `build_command_list/3` returning flat `[command | args]` for port/System.cmd convenience.

### Step 44: Handle writable workspace directory ✅
`--add-dirs=<workspace_path>` — agent gets read/write access to workspace.

### Step 45: Handle read-only paths ✅
`--add-dirs-ro=<paths>` — for any shared reference directories. Multiple read-only dirs supported via `:read_only_dirs` option.

### Step 46: Handle environment variable forwarding ✅
`--env-pass=<VAR1>,<VAR2>` — forward API keys into the sandbox. Agent's required env vars merged with extra vars from `:env_vars` option, deduplicated.

### Step 47: Handle agent-specific flags ✅
Each agent has its own skip-permissions flag. Safehouse module combines safehouse flags + `--` separator + agent command + agent flags. Skip-permissions defaults to true, configurable via `:skip_permissions` option.

### Step 48: Write unit tests for Safehouse command building ✅
`test/symphony_v2/agents/safehouse_test.exs` — 27 tests covering: all 4 agent types, read-only dirs, env var forwarding and dedup, skip-permissions toggle, unknown agent errors, path safety (null bytes, semicolons, pipes, ampersands, backticks, command substitution, newlines, empty paths), safe path acceptance (spaces, dots, parent refs), and `build_command_list/3`. 252 tests total, 0 failures. Full quality gate passes.

---

## Phase 7: Agent Execution Engine (Steps 49–60) ✅ DONE

### Step 49: Create AgentProcess GenServer ✅
`lib/symphony_v2/agents/agent_process.ex` — GenServer managing a single agent CLI process via Erlang Port.

### Step 50: Implement `start_link/1` ✅
Accepts: `%{agent_type: atom, workspace: String.t, agent_run_id: uuid, prompt: String.t, caller: pid, timeout_ms: integer, safehouse_opts: keyword}`.

### Step 51: Implement `init/1` — spawn the CLI process ✅
Resolves command via Safehouse (or `command_override` for testing), opens Erlang Port with `:spawn_executable`, `cd: workspace`, `stderr_to_stdout: true`. Creates log file at `<workspace>/.symphony/logs/<agent_run_id>.log`.

### Step 52: Handle stdout/stderr streaming ✅
`handle_info({port, {:data, data}}, state)` — accumulates output, writes to log file, broadcasts via PubSub.

### Step 53: Implement PubSub broadcasting of agent output ✅
Topic: `"agent_output:#{agent_run_id}"` — broadcasts `{:agent_output, id, text}` for each chunk and `{:agent_complete, id, result}` on completion.

### Step 54: Handle process exit ✅
`handle_info({port, {:exit_status, status}}, state)` — records exit code, computes duration, notifies caller via `{:agent_complete, result}` message.

### Step 55: Implement timeout handling ✅
`Process.send_after(self(), :timeout, timeout_ms)` in init. On timeout, kills port OS process via `kill -9`, reports timeout status. Handles late exit_status messages after timeout.

### Step 56: Implement clean shutdown ✅
`terminate/2` — closes log file, kills port process if still open.

### Step 57: Persist agent run results ✅
On completion/failure/timeout, updates the AgentRun record in Postgres with exit_code, duration_ms, stdout_log_path, status, completed_at.

### Step 58: Create AgentSupervisor ✅
`lib/symphony_v2/agents/agent_supervisor.ex` — DynamicSupervisor for AgentProcess instances. `:one_for_one` strategy with `:temporary` restart on children. Added to application supervision tree. Provides `start_agent/1`, `running_count/0`.

### Step 59: Write unit tests for AgentProcess ✅
`test/symphony_v2/agents/agent_process_test.exs` — 7 tests covering: successful execution with output capture and DB persistence, failed execution (exit code 1), timeout handling with kill, PubSub broadcasting, AgentSupervisor start_agent and running_count, multi-line output capture.

### Step 60: Write integration test ✅
Real shell scripts run through AgentProcess → verifies log file written, AgentRun record updated in DB, caller notified, PubSub broadcasts sent. 259 tests total, 0 failures. Coverage 90.39%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 8: Workspace Management (Steps 61–68) ✅ DONE

### Step 61: Create Workspace module ✅
`lib/symphony_v2/workspace.ex` — manages per-task workspace directories. Pure functions taking workspace_root and task_id parameters.

### Step 62: Implement `create/2` ✅
Creates directory at `<workspace_root>/task-<task_id>/`. Expands paths to prevent traversal. Returns `{:ok, path}` or `{:error, reason}`.

### Step 63: Implement `clone_repo/2` ✅
`git clone <repo_path> <workspace_path>` — clones the configured repo into the workspace via `System.cmd`. Returns `{:ok, path}` or `{:error, {:clone_failed, exit_code, output}}`.

### Step 64: Implement `validate_path/2` ✅
Resolves symlinks via `File.lstat`, verifies path is under `workspace_root` via `Path.expand`. Prevents path traversal (`../`), symlink escape, and path-equals-root. Walks each path component checking for symlinks.

### Step 65: Implement `cleanup/2` ✅
`File.rm_rf` after validation. Validates path is under workspace_root before deletion. Returns `{:ok, paths}` or `{:error, reason}`.

### Step 66: Implement `exists?/2` ✅
Checks if workspace directory exists for a given task (for restart recovery — don't re-clone).

### Step 67: Write unit tests for path validation ✅
`test/symphony_v2/workspace_test.exs` — tests for: valid paths, nested paths, path-equals-root rejection, path-outside-root rejection, path traversal via `..`, symlink escape detection, paths with spaces.

### Step 68: Write integration test for full lifecycle ✅
Full lifecycle test: create workspace → clone repo → verify git repo initialized and files present → verify exists? → cleanup → verify removed. 278 tests total, 0 failures. Coverage 90.29%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 9: Git Operations (Steps 69–82) ✅ DONE

### Step 69: Create GitOps module ✅
`lib/symphony_v2/git_ops.ex` — all git operations as pure functions taking workspace path. Uses `System.cmd("git", ["-C", workspace | args])` pattern with `{:ok, result} | {:error, reason}` tuples.

### Step 70: Implement `current_branch/1` ✅
`git -C <workspace> rev-parse --abbrev-ref HEAD` — return current branch name.

### Step 71: Implement `checkout_main/1` ✅
`git -C <workspace> checkout main` — ensure we start from main.

### Step 72: Implement `create_branch/2` ✅
`git -C <workspace> checkout -b <branch_name>` — create and switch to new branch.

### Step 73: Define branch naming convention ✅
`symphony/<task_id>/step-<position>-<slug>` where slug is derived from subtask title (lowercase, hyphens, truncated to 50 chars). `slugify/1` public function.

### Step 74: Implement `create_stacked_branch/3` ✅
For subtask at position N > 1: checkout the branch from position N-1, then create new branch. This builds the stack.

### Step 75: Implement `has_changes?/1` ✅
`git -C <workspace> status --porcelain` — return true if any changes.

### Step 76: Implement `changed_files/1` ✅
`git -C <workspace> status --porcelain` — return list of changed file paths (handles modified, new, deleted, renamed).

### Step 77: Implement `stage_and_commit/2` ✅
`git add -A` + `git commit -m` + `git rev-parse HEAD`. Returns `{:ok, commit_sha}` or `{:error, :nothing_to_commit}`.

### Step 78: Implement `push/2` ✅
`git -C <workspace> push -u origin <branch_name>`. Also `force_push/2` with `--force-with-lease`.

### Step 79: Implement `create_pr/4` ✅
`lib/symphony_v2/git_ops/github.ex` — separated into `GitOps.GitHub` module. Uses `gh pr create` with `--repo`, `--head`, `--base`, `--title`, `--body` options. Returns `{:ok, %{url: url, number: number}}`. Delegated from `GitOps`.

### Step 80: Implement `rebase_onto/2` ✅
`git -C <workspace> rebase <target>`. On failure, aborts rebase and returns `{:error, :conflict}`.

### Step 81: Implement `rebase_stack_onto_main/2` ✅
Recursive: checkout each branch bottom-up, rebase onto main (first) or onto the rebased previous branch (subsequent). Returns `{:error, {:conflict, branch_name}}` on failure.

### Step 82: Implement `merge_stack/2` ✅
`lib/symphony_v2/git_ops/github.ex` — `merge_pr/2` and `merge_stack/2`. Merges PRs bottom-up via `gh pr merge`. Returns `{:ok, [merged_numbers]}` or `{:error, {:merge_failed_at, number, reason}}`.

Additional: `diff/3`, `diff_stat/3`, `diff_name_only/3`, `reset_hard/1`, `clean/1` utility functions.

---

## Phase 10: Git Operations Testing (Steps 83–86) ✅ DONE

### Step 83: Write unit tests for branch naming ✅
`test/symphony_v2/git_ops_test.exs` — 10 tests for `branch_name/3` and `slugify/1`: generation, special characters, truncation, trailing hyphen prevention, unicode, empty strings.

### Step 84: Create test helper for temp git repos ✅
`test/support/git_test_helper.ex` — `init_temp_repo/1` (basic repo), `init_temp_repo_with_remote/1` (with bare remote for push testing), `write_and_commit/4`, `git!/2` helper.

### Step 85: Write integration tests for basic git operations ✅
Tests for: `current_branch`, `checkout_main`, `checkout`, `create_branch`, `has_changes?`, `changed_files`, `stage_and_commit`, `push`, `force_push`, `diff`, `diff_stat`, `diff_name_only`, `reset_hard`, `clean` — all against real temp git repos.

### Step 86: Write integration tests for stacked branch workflow ✅
Create a stack of 3 branches with incremental work, verify file isolation per branch, verify `rebase_stack_onto_main` works cleanly and handles conflicts correctly. 328 tests total, 0 failures. Coverage 90.13%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 11: Test Runner (Steps 87–92) ✅ DONE

### Step 87: Create TestRunner module ✅
`lib/symphony_v2/test_runner.ex` — runs the configured test command in a workspace via Erlang Port with `sh -c` for shell command support.

### Step 88: Implement `run/3` ✅
Takes workspace path, test command, and options. Executes via Erlang Port with `stderr_to_stdout`. Captures stdout/stderr, exit code. Returns `{:ok, TestResult.t()}` or `{:error, term()}`.

### Step 89: Return structured result ✅
`lib/symphony_v2/test_runner/test_result.ex` — enforced keys struct:
```elixir
%TestResult{
  passed: boolean,
  exit_code: integer,
  output: String.t(),
  duration_ms: integer
}
```

### Step 90: Implement timeout handling ✅
Configurable via `:timeout_ms` option (default: 300_000ms / 5 min). Uses `Process.send_after` + `kill -9` on timeout. Returns exit_code 137 and appends `[TEST TIMEOUT]` to output. Drains remaining port messages after kill.

### Step 91: Persist test results ✅
`run_and_persist/4` — writes test output to `<workspace>/.symphony/logs/test_output.log`, updates subtask record with `test_passed` and `test_output` (truncated to 100KB). Handles workspace validation and DB persistence errors gracefully.

### Step 92: Write tests for TestRunner ✅
`test/symphony_v2/test_runner_test.exs` — 17 tests covering: successful/failed commands, stdout/stderr capture, multi-line output, workspace directory execution, non-existent workspace error, non-zero exit codes, duration measurement, timeout with kill, partial output before timeout, DB persistence of pass/fail results, log file writing, TestResult struct enforcement. 366 tests total, 0 failures. Coverage 93.43%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 12: Planning Agent Integration (Steps 93–104) ✅ DONE

### Step 93: Define plan file JSON schema ✅
JSON structure with `tasks` array containing objects with `position`, `title`, `spec`, and `agent_type` fields.

### Step 94: Document plan file contract ✅
`docs/plan-file-format.md` — documents required fields, valid agent types, ordering rules, validation rules, and examples.

### Step 95: Create PlanParser module ✅
`lib/symphony_v2/plans/plan_parser.ex` — parses and validates plan.json files. Functions: `parse/1` (from file), `parse_map/1` (from decoded map).

### Step 96: Implement `parse/1` ✅
Reads file, decodes JSON, validates structure. Returns `{:ok, [%{position, title, spec, agent_type}]}` or `{:error, reason}`.

### Step 97: Validate plan contents ✅
Validates: sequential positions starting from 1, all agent types registered in AgentRegistry, non-empty title/spec strings, at least one task, all entries are maps.

### Step 98: Create PlanningAgent module ✅
`lib/symphony_v2/agents/planning_agent.ex` — orchestrates the full planning step from prompt building through plan parsing and DB record creation.

### Step 99: Build the planning prompt ✅
`build_prompt/1` constructs prompt with task title, description, relevant files, available agent types, plan.json format specification, and ordering rules.

### Step 100: Invoke planning agent ✅
Uses configured planning agent type. Creates AgentRun record, launches via AgentSupervisor/AgentProcess with safehouse or command_override support. Waits for completion with configurable timeout.

### Step 101: After agent exit — parse plan ✅
Locates `plan.json` in workspace root. Parses via PlanParser. Returns structured subtask entries.

### Step 102: On success — create database records ✅
Updates ExecutionPlan with raw_plan and plan_file_path. Creates Subtask records from parsed plan. Transitions task to `plan_review`. Cleans up temporary planning subtask.

### Step 103: On failure — handle gracefully ✅
No plan file, invalid format, malformed JSON, empty tasks, or agent error → marks task as `failed` with descriptive error messages. Handles all error cases: file_not_found, invalid_json, empty_tasks, missing_tasks_key, invalid_tasks, invalid_positions, unknown_agent_types, agent_failed, agent_timeout.

### Step 104: Write tests ✅
`test/symphony_v2/plans/plan_parser_test.exs` — 20 unit tests for PlanParser: valid parsing, file errors, JSON errors, missing/empty tasks, field validation, position validation, agent type validation, sorting, parse_map.
`test/symphony_v2/agents/planning_agent_test.exs` — 12 tests: prompt building (5 tests), plan_file_path, integration with mock agents (6 tests covering success, agent failure, missing plan, invalid plan, timeout, malformed JSON). 398 tests total, 0 failures. Coverage 93.20%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 13: Review Agent Integration (Steps 105–114) ✅ DONE

### Step 105: Create ReviewAgent module ✅
`lib/symphony_v2/agents/review_agent.ex` — orchestrates the review step for a subtask. Uses `with` chain: validate different agent type → get diff → build prompt → create agent run → launch agent → parse review → apply verdict.

### Step 106: Build review prompt ✅
`build_prompt/2` includes subtask title, spec, git diff, and detailed review instructions covering: corner-cutting, meaningless tests, hardcoded values, skipped requirements, code quality.

### Step 107: Define review output format ✅
```json
{
  "verdict": "approved" | "rejected",
  "reasoning": "The implementation correctly...",
  "issues": [
    {"severity": "critical" | "major" | "minor" | "nit", "description": "..."}
  ]
}
```

### Step 108: Create ReviewParser module ✅
`lib/symphony_v2/agents/review_parser.ex` — parses and validates review.json. Functions: `parse/1` (from file), `parse_map/1` (from decoded map). Validates: verdict (approved/rejected), reasoning (non-empty string), issues (optional list with severity/description per entry).

### Step 109: Invoke review agent ✅
Enforces **different agent type** than the executor via `validate_different_agent/2`. Builds safehouse command, launches via AgentProcess/AgentSupervisor. Supports `:diff` option for pre-computed diffs, `:agent_type` override, configurable timeout.

### Step 110: After agent exit — parse review ✅
Locates `review.json` in workspace root. Parses via ReviewParser. Returns structured review with verdict, reasoning, and issues.

### Step 111: On approval — update subtask ✅
Sets `review_verdict: "approved"`, `review_reasoning: reasoning`, `status: "succeeded"` via `Plans.update_subtask/2`.

### Step 112: On rejection — trigger retry ✅
Sets `review_verdict: "rejected"`, `review_reasoning: reasoning`, `last_error: reasoning`. Does NOT change subtask status — leaves that for Pipeline retry logic.

### Step 113: On review failure — handle gracefully ✅
All error cases handled: file_not_found, invalid_json, invalid_review_format, missing_verdict, invalid_verdict, missing_reasoning, empty_reasoning, issues_must_be_list, invalid_issues, agent_failed, agent_timeout, same_agent_type, no_changes, diff_failed. Updates subtask `last_error` with descriptive message.

### Step 114: Write tests ✅
`test/symphony_v2/agents/review_parser_test.exs` — 21 unit tests: valid parsing (approved/rejected/no issues/empty issues/all severities), file errors, verdict validation, reasoning validation, issues validation (missing fields, invalid severity, non-map entries), format errors, parse_map.
`test/symphony_v2/agents/review_agent_test.exs` — 19 tests: prompt building (4 tests), review_file_path, integration with mock agents (12 tests covering approved, rejected, agent failure, missing review, timeout, invalid JSON, same-agent-type rejection, missing verdict, non-map JSON, invalid verdict, empty reasoning, invalid issues), compute_diff via git (2 tests covering diff_failed and no_changes). 438 tests total, 0 failures. Coverage 92.90%. Full quality gate passes (compile, format, credo strict, dialyzer).

---

## Phase 14: Execution Pipeline (Steps 115–137) ✅ DONE

### Step 115: Create Pipeline GenServer ✅
`lib/symphony_v2/pipeline.ex` — the core orchestrator GenServer that drives the entire execution flow. Public API: `start_link/1`, `check_queue/1`, `approve_plan/1`, `reject_plan/1`, `approve_final/1`, `get_state/1`.

### Step 116: Define Pipeline state ✅
```elixir
%{
  status: :idle | :processing,
  current_task_id: uuid | nil,
  current_subtask_id: uuid | nil,
  current_step: :planning | :awaiting_plan_review | :executing_subtask | :testing | :reviewing | :awaiting_final_review | :merging | nil,
  workspace: String.t() | nil,
  config: AppConfig.t() | nil
}
```

### Step 117: Implement `init/1` — recovery from database ✅
On startup, checks Postgres for tasks in `executing`, `planning`, or `plan_review` state (priority order). If found, recovers pipeline state including workspace path.

### Step 118: Implement task pickup — `check_queue/0` ✅
`handle_cast(:check_queue)` — finds next task in `planning` status via `Tasks.next_queued_task/0`. Ignores when already processing.

### Step 119: Implement planning step ✅
1. Create workspace (Workspace.create + clone_repo) or reuse existing
2. Launch planning agent (PlanningAgent.run)
3. On success: transition to plan_review (or auto-approve if dangerously_skip_permissions)
4. On failure: mark task failed, return to idle

### Step 120: Implement `approve_plan/1` ✅
Called from UI. Transitions plan to `executing`, task to `executing`. Triggers first subtask execution.

### Step 121: Implement `reject_plan/1` ✅
Called from UI. Transitions task back to `planning` and re-runs planning agent.

### Step 122: Implement subtask execution — single subtask flow ✅
1. Get next pending subtask via `Plans.next_pending_subtask/1`
2. Create branch (stacked on previous subtask's branch for position > 1)
3. Update subtask with branch_name, status → `dispatched`
4. Build prompt from subtask spec (with error context from retries)
5. Create AgentRun record, launch via AgentSupervisor
6. Update subtask status → `running`
7. Wait for agent completion via receive

### Step 123: Implement post-agent — change detection ✅
On agent success: check `GitOps.has_changes?`. No changes → failure ("agent made no changes"). Changes → proceed to testing.

### Step 124: Implement testing step ✅
Update subtask → `testing`. Run `TestRunner.run_and_persist`. Pass → commit/push/PR. Fail → retry with test output as error context.

### Step 125: Implement commit and PR creation ✅
`GitOps.stage_and_commit` → `GitOps.push` → `GitOps.GitHub.create_pr` with correct base branch (main for first, previous subtask's branch for subsequent). Stores branch_name, pr_url, pr_number, commit_sha, files_changed. PR creation failure is non-fatal — continues to review.

### Step 126: Implement review step ✅
Update subtask → `in_review`. Launch ReviewAgent with computed diff. On approval: advance. On rejection: retry. On same-agent-type or review failure: auto-approve and continue.

### Step 127: Implement subtask retry logic ✅
Increment retry_count. If retries remain: `git reset --hard` + `git clean -fd`, reset subtask to `pending` with error context, re-execute. If exhausted: mark subtask `failed`, fail task.

### Step 128: Implement subtask advancement ✅
After subtask succeeds: send `{:continue, :execute_next_subtask}` to self. When no pending subtasks remain and all succeeded → transition to awaiting_final_review.

### Step 129: Implement `approve_final/1` ✅
Called from UI. Triggers merge flow.

### Step 130: Implement merge flow ✅
`GitOps.rebase_stack_onto_main` → force push rebased branches → `GitOps.GitHub.merge_stack` bottom-up. On conflict: fail with branch info. On merge failure: fail with PR number.

### Step 131: Implement dangerously-skip-permissions mode ✅
Auto-approves plan after successful parsing (skips plan_review gate). Auto-approves and triggers merge after all subtasks pass (skips awaiting_final_review gate).

### Step 132: Implement task completion ✅
Mark task `completed`. Cleanup workspace. Broadcast completion. Return to idle and check queue for next task.

### Step 133: Implement task failure handling ✅
Mark task `failed`. Broadcast failure. Return to idle and check queue.

### Step 134: Implement PubSub broadcasts ✅
Broadcasts on every state transition:
- Topic `"pipeline"` — `{:pipeline_started, task_id}`, `{:pipeline_idle, task_id}`
- Topic `"task:#{task_id}"` — `{:task_step, step}`, `{:task_completed, task_id}`, `{:task_failed, reason}`
- Topic `"subtask:#{subtask_id}"` — `{:subtask_started, pos}`, `{:subtask_running, pos}`, `{:subtask_testing, pos}`, `{:subtask_reviewing, pos}`, `{:subtask_succeeded, pos}`, `{:subtask_failed, pos, error}`, `{:subtask_retrying, pos, count}`

### Step 135: Add Pipeline to supervision tree ✅
Added as named GenServer in `application.ex` between AgentSupervisor and Endpoint. Default restart strategy: `:permanent`.

### Step 136: Write unit tests for pipeline state machine ✅
`test/symphony_v2/pipeline_test.exs` — 10 tests covering: idle startup, recovery from executing/plan_review states, check_queue behavior (empty queue, already processing), approve/reject/final errors when not in correct state, get_state returns state without config, PubSub integration.

### Step 137: Write integration tests ✅
Recovery tests verify pipeline resumes from DB state on restart. State machine guards tested for all public API calls. 448 tests total, 0 failures. Full quality gate passes (compile --warnings-as-errors, format, credo strict, dialyzer).

---

## Phase 15: Task Management UI (Steps 138–152)

### Step 138: Create root layout
`lib/symphony_v2_web/components/layouts/root.html.heex` — navigation bar with links: Tasks, Dashboard, Settings. Show current user + logout.

### Step 139: Create app layout
`lib/symphony_v2_web/components/layouts/app.html.heex` — flash messages, main content area.

### Step 140: Create TaskLive.Index
`lib/symphony_v2_web/live/task_live/index.ex` — list all tasks grouped by status. Columns: title, status badge, creator, created date, queue position.

### Step 141: Implement status filtering
Tabs or sidebar filters: All, Queued, In Progress, Completed, Failed.

### Step 142: Create TaskLive.New
`lib/symphony_v2_web/live/task_live/new.ex` — form with:
- Title (text input, required)
- Description (textarea, required)
- Relevant files/constraints (textarea, optional)
- Request team review (checkbox)
- Submit button

### Step 143: Implement task creation
Form submission → Tasks.create_task → redirect to task detail page.

### Step 144: Create TaskLive.Show
`lib/symphony_v2_web/live/task_live/show.ex` — full task detail:
- Task metadata (title, description, status, creator)
- If awaiting_review: "Approve" button (visible to non-creator users only)
- If has execution plan: show plan summary with subtask list
- If executing: show current progress
- If completed: show PR links
- If failed: show error details

### Step 145: Implement task review approval
"Approve" button → Tasks.approve_task_review → triggers pipeline.

### Step 146: Subscribe to PubSub for real-time updates
TaskLive.Show subscribes to `"task:#{task_id}"` topic. Updates status, progress, subtask states in real time.

### Step 147: Add status badges with color coding
Draft: gray. Awaiting review: yellow. Planning: blue. Executing: blue animated. Completed: green. Failed: red.

### Step 148: Add queue management
On TaskLive.Index: show queue position for pending tasks. Optional: reorder tasks in queue.

### Step 149: Write LiveView test for task list page

### Step 150: Write LiveView test for task creation

### Step 151: Write LiveView test for task detail page

### Step 152: Write LiveView test for review approval flow

---

## Phase 16: Plan Review & Editing UI (Steps 153–165)

### Step 153: Create PlanLive.Show
`lib/symphony_v2_web/live/plan_live/show.ex` — display execution plan for a task.

### Step 154: Render subtask list
Ordered list showing: position, title, spec (truncated, expandable), agent type badge, status.

### Step 155: Add "Approve Plan" button
Visible when plan status is `awaiting_review`. Triggers Pipeline.approve_plan.

### Step 156: Add "Reject & Re-plan" button
Returns task to planning state for another planning agent attempt.

### Step 157: Implement subtask spec editing
Click on a subtask → expand inline editor for the spec text. Save updates to database.

### Step 158: Implement agent type reassignment
Dropdown per subtask to change agent type. Options populated from AgentRegistry.

### Step 159: Implement subtask reordering
Up/down arrow buttons to move subtasks. Update position fields in database.

### Step 160: Implement add subtask
"Add subtask" button → inline form at specified position. Resequence subsequent positions.

### Step 161: Implement remove subtask
Delete button per subtask (with confirmation). Resequence remaining positions.

### Step 162: Save all plan edits
Edits update the database immediately (or batch save with a "Save changes" button).

### Step 163: Write LiveView test for plan display

### Step 164: Write LiveView test for subtask editing

### Step 165: Write LiveView test for subtask reordering/add/remove

---

## Phase 17: Execution Monitoring Dashboard (Steps 166–179)

### Step 166: Create DashboardLive
`lib/symphony_v2_web/live/dashboard_live.ex` — main monitoring page.

### Step 167: Pipeline status indicator
Show current pipeline state: idle, planning, executing, merging. With task name if processing.

### Step 168: Current task progress section
Show task title, description, and which phase it's in (planning → plan review → executing → final review → merging).

### Step 169: Subtask progress display
Visual list of subtasks with status indicators:
- Pending: gray circle
- Running: blue spinner
- Testing: yellow circle
- In review: purple circle
- Succeeded: green checkmark
- Failed: red X

### Step 170: Active agent output streaming
When an agent is running, stream its stdout in a terminal-like view. Subscribe to `"agent_output:#{agent_run_id}"` PubSub topic.

### Step 171: Subtask detail expansion
Click on a subtask to expand: full spec, agent type, test results, review verdict, PR link, retry history.

### Step 172: Test results display
Per subtask: show pass/fail badge, expandable test output.

### Step 173: Review verdicts display
Per subtask: show approved/rejected badge, review reasoning, list of issues flagged.

### Step 174: PR links
Per completed subtask: clickable link to GitHub PR.

### Step 175: Retry history
Per subtask: show attempt count, previous error messages, which attempt succeeded.

### Step 176: Task queue sidebar
Show upcoming tasks in queue order. Current task highlighted.

### Step 177: Manual pipeline controls
- "Pause" button: stop after current subtask completes
- "Resume" button: continue paused pipeline
- "Skip subtask" button: mark current subtask as skipped, advance
- "Retry" button: retry a failed subtask manually

### Step 178: Subscribe to PubSub for all real-time updates
Subscribe to `"pipeline"`, `"task:#{id}"`, `"subtask:#{id}"`, `"agent_output:#{id}"` topics.

### Step 179: Write LiveView tests for dashboard rendering and updates

---

## Phase 18: PR Stack Review UI (Steps 180–187)

### Step 180: Create StackReviewLive
`lib/symphony_v2_web/live/stack_review_live.ex` — PR stack review page for completed tasks awaiting final review.

### Step 181: List all PRs in the stack
Ordered list: PR number, title, link to GitHub, base branch, diff stats (files changed, +/- lines).

### Step 182: Per-PR summary
Show files changed, review agent verdict, key observations from review.

### Step 183: "Approve & Merge" button
Triggers Pipeline.approve_final → rebase + merge flow.

### Step 184: "Reject" button with feedback
Textarea for human feedback. Returns task to failed state with feedback stored.

### Step 185: Merge progress display
Real-time updates: "Rebasing onto main...", "Merging PR 1/4...", "Complete" or "Conflict detected in PR 2".

### Step 186: Conflict error display
If rebase fails: show which file(s) conflict, which subtask's PR. Provide options: "Retry" or "Resolve manually".

### Step 187: Write LiveView tests for stack review flow

---

## Phase 19: Application Wiring & Supervision (Steps 188–195)

### Step 188: Define full supervision tree
```elixir
children = [
  SymphonyV2.Repo,
  {Phoenix.PubSub, name: SymphonyV2.PubSub},
  {SymphonyV2.Agents.AgentSupervisor, []},
  SymphonyV2.Pipeline,
  SymphonyV2Web.Endpoint
]
```

### Step 189: Configure startup order
Repo must start before Pipeline (DB access). PubSub must start before Pipeline and Endpoint. AgentSupervisor must start before Pipeline.

### Step 190: Implement graceful shutdown
On application stop: Pipeline completes or checkpoints current step. AgentSupervisor terminates running agents cleanly.

### Step 191: Implement restart recovery
Pipeline.init reads from DB: if a task is in-progress, determine the last completed step and resume from there.

### Step 192: Handle child crashes
- AgentProcess crash: Pipeline detects via monitor, treats as agent failure, enters retry logic.
- Pipeline crash: Supervisor restarts it, Pipeline.init recovers from DB.
- Repo crash: Application-level failure, supervisor restarts.

### Step 193: Configure PubSub topics
Document all topics and their payload shapes in a module:
```elixir
defmodule SymphonyV2.PubSub.Topics do
  def pipeline, do: "pipeline"
  def task(id), do: "task:#{id}"
  def subtask(id), do: "subtask:#{id}"
  def agent_output(id), do: "agent_output:#{id}"
end
```

### Step 194: Write application startup tests
Verify all children start in correct order, DB is accessible, Pipeline initializes.

### Step 195: Write crash recovery tests
Kill Pipeline, verify restart and state recovery from DB.

---

## Phase 20: Settings UI (Steps 196–201)

### Step 196: Create SettingsLive
`lib/symphony_v2_web/live/settings_live.ex` — view current application configuration.

### Step 197: Display current config
Show: repo path, workspace root, test command, planning agent, review agent, default agent, max retries, timeout, dangerously-skip-permissions toggle.

### Step 198: Display agent registry
Table of configured agents: name, CLI command, skip-permissions flag, required env vars, installed status.

### Step 199: Implement config editing
Allow editing test command, default agents, max retries, timeout, dangerously-skip-permissions. Persist to database or config file.

### Step 200: Implement agent management
Add/remove/edit agent configurations. Validate that the CLI command exists on the system.

### Step 201: Write tests for settings page

---

## Phase 21: End-to-End Testing & Hardening (Steps 202–220)

### Step 202: Create mock agent script
A simple shell script that simulates an agent: reads a prompt, writes files to the workspace, exits 0. Parameterizable for different behaviors (success, failure, writes plan.json, writes review.json).

### Step 203: E2E test — happy path
Task creation → planning → plan approval → subtask execution → tests pass → PR created → review approved → final approval → merge. All with mock agents.

### Step 204: E2E test — review requested flow
Task created with review_requested → second user approves → proceeds to planning.

### Step 205: E2E test — subtask failure and retry
Agent fails (exit code 1) → retry with error context → succeeds on second attempt.

### Step 206: E2E test — tests fail and retry
Agent succeeds but tests fail → retry → agent fixes, tests pass.

### Step 207: E2E test — review rejection and retry
Review agent rejects work → retry with feedback → second attempt approved.

### Step 208: E2E test — retries exhausted
Agent fails max_retries + 1 times → task marked failed → error surfaced.

### Step 209: E2E test — plan rejection and re-plan
Human rejects plan → re-planning → new plan → approval → execution.

### Step 210: E2E test — dangerously-skip-permissions
Full automation: task → plan → execute → merge with no human gates.

### Step 211: E2E test — rebase conflict during merge
Simulate main advancing with conflicting changes → rebase fails → error surfaced to human.

### Step 212: E2E test — pipeline restart recovery
Start processing a task → kill Pipeline GenServer → restart → verify it resumes from correct step.

### Step 213: E2E test — multiple tasks queued
Create 3 tasks → verify they execute sequentially in queue order.

### Step 214: Security review — Safehouse command construction
Verify no shell injection possible via task titles, descriptions, file paths, agent names. Test with adversarial inputs.

### Step 215: Security review — workspace path safety
Verify path traversal impossible. Test with `../`, symlinks, etc.

### Step 216: Performance test — large agent output
Agent that produces megabytes of stdout → verify no memory issues in AgentProcess or PubSub.

### Step 217: Performance test — long-running agent
Agent that runs for configured timeout → verify clean timeout and kill.

### Step 218: Manual testing guide
Document how to test with real agents (Claude Code, Codex) against a test repo. Step-by-step instructions.

### Step 219: Update project documentation
- Update repo `README.md` with v2 section
- Create `v2/README.md` with setup and usage instructions
- Update `CLAUDE.md` with v2 build/test commands

### Step 220: Final cleanup
Remove any scaffolding code, ensure all tests pass, run full quality gate (`make all`).

---

## Summary

| Phase | Steps | Description |
|-------|-------|-------------|
| 1. Project Bootstrap | 1–8 | ✅ New Phoenix app, toolchain, Makefile |
| 2. Authentication | 9–16 | ✅ Password auth, seed user, protected routes |
| 3. Data Model — Tasks | 17–27 | ✅ Tasks, execution plans, subtasks schemas |
| 4. Data Model — Agent Runs | 28–33 | ✅ Agent run tracking, Plans context |
| 5. App Configuration | 34–41 | ✅ Config loading, agent registry |
| 6. Safehouse Integration | 42–48 | ✅ CLI command builder for sandboxed agents |
| 7. Agent Execution Engine | 49–60 | ✅ GenServer wrapping CLI processes |
| 8. Workspace Management | 61–68 | ✅ Per-task directory lifecycle |
| 9. Git Operations | 69–82 | ✅ Branch, commit, push, PR, stack management |
| 10. Git Testing | 83–86 | ✅ Integration tests for git operations |
| 11. Test Runner | 87–92 | ✅ Execute test commands, capture results |
| 12. Planning Agent | 93–104 | ✅ Plan file format, parsing, planning flow |
| 13. Review Agent | 105–114 | ✅ Review file format, parsing, review flow |
| 14. Execution Pipeline | 115–137 | ✅ Core orchestrator GenServer |
| 15. Task Management UI | 138–152 | Task CRUD, list, detail, review LiveViews |
| 16. Plan Review UI | 153–165 | Plan display, editing, approval LiveViews |
| 17. Monitoring Dashboard | 166–179 | Real-time execution monitoring |
| 18. PR Stack Review UI | 180–187 | Final review and merge UI |
| 19. App Wiring & Supervision | 188–195 | Supervisor tree, recovery, PubSub |
| 20. Settings UI | 196–201 | Configuration management UI |
| 21. E2E Testing & Hardening | 202–220 | Full integration tests, security, docs |

**Total: 220 discrete implementation steps across 21 phases.**
