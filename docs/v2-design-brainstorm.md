# Symphony v2 — Design Brainstorm

Captured from initial design conversation. Reference for future planning and implementation.

## Motivation

The current Symphony orchestrates Codex agents against Linear issues. Two fundamental problems:

1. **Single-agent lock-in.** Only supports Codex. Want to dispatch the best agent for each task (Claude Code/Opus, Codex, Gemini CLI, Opencode, etc.).
2. **Linear is built for humans, not agents.** Polling is wasteful, issue structure is noise to agents, state machine is too shallow, no dependency graph, no artifact tracking, API rate limits. Rather than adapting a human tool, build a purpose-built system.

## Core Design Decisions

### Self-contained system, no external dependencies

- Drop Linear entirely. Symphony v2 is a standalone Phoenix/Postgres app.
- Own task intake UI, planning, execution, and observability.
- Single repo per instance (multi-repo deferred).

### Human-agent collaborative planning

- A planning agent (Opus-tier) decomposes high-level tasks into ordered sub-tasks.
- The planning agent also assigns the best coding agent per sub-task based on task characteristics.
- The planning agent runs as a normal agent inside Safehouse with full workspace permissions. It explores the codebase, and writes a plan file (`plan.json` or `plan.yaml`) to the workspace. Symphony reads it after the agent exits.
- Humans can review and edit the execution plan in the dashboard before it runs.
- This is the default mode. A "dangerously-skip-permissions" option allows full end-to-end automation with no human oversight.

### Task intake

- Lightweight web form: title, description, relevant files/constraints.
- Optional "request team review" checkbox — if checked, another team member must approve before automation starts. If unchecked, automation picks it up immediately.
- No role-based permissions. All team members can create and approve tasks.
- Simple rule: if review is requested, someone *other than the creator* must approve.

### Multi-agent dispatch

- Motivation: pick the best tool for each job, not vendor lock-in or agent competition.
- **All agents run via CLI**, not JSON-RPC or structured protocols. Unified execution model.
- Each agent is wrapped in a GenServer that monitors stdout/stderr to completion.
- Planning agent selects agent type per sub-task.

### Agent sandboxing via Safehouse

- All agents run inside [Agent Safehouse](https://agent-safehouse.dev/docs/) — a macOS kernel-level sandbox using `sandbox-exec`.
- Deny-first policy: filesystem access defaults to restricted, explicit allow grants for workspace directories.
- Because Safehouse provides isolation at the OS level, **all agents run with skip-permissions flags**:
  - Claude Code: `safehouse claude --dangerously-skip-permissions`
  - Codex: `safehouse codex --dangerously-bypass-approvals-and-sandbox`
  - Other agents: similar pattern
- This eliminates the need for per-agent approval/sandbox configuration — Safehouse handles it uniformly.
- Workspace directories are granted via `--add-dirs` (writable) and `--add-dirs-ro` (read-only for shared libs/context).
- Environment variables (API keys) passed via `--env-pass` or `--env=<file>`.
- The GenServer wrapping each agent invocation builds the full `safehouse` CLI command with appropriate flags, then monitors the process.
- This means the Codex JSON-RPC `AppServer` client from v1 is no longer needed. All agents are CLI processes with stdout/stderr streaming.

### Sequential execution — fully sequential

- **One top-level task at a time.** Tasks queue up and execute in order. No parallel top-level tasks.
- Sub-tasks within a plan execute sequentially, each branching from the previous result (stacked PRs).
- Benefits:
  - Eliminates merge conflicts entirely — no agents stepping on each other.
  - Each agent sees the previous agent's work as context.
  - Small, focused diffs for human review.
  - Failure isolation — completed sub-tasks are preserved, re-plan from failure point.
- Tradeoff: slower than parallel execution. Accepted deliberately for simplicity and safety.
- Parallel top-level tasks (via git worktrees) deferred as future evolution.

### Git operations owned by Symphony

- **Symphony owns the full git lifecycle**, not the agents.
- Before each sub-task: Symphony creates the branch (stacked on previous sub-task's branch).
- Agent runs, writes code, makes tests pass. Agent does NOT push, create PRs, or manage branches.
- After agent exits: Symphony inspects `git diff` to determine changes, commits, pushes, opens the PR with correct stacking base.
- This ensures consistent branch naming, stacking order, and PR creation.
- No GitHub token needed inside the Safehouse sandbox — cleaner security posture.

### Stacked PR merge strategy

- When human approves the full stack: **rebase the stack onto current main**, then merge bottom-up.
- If rebase hits conflicts, surface to human (agent-assisted conflict resolution deferred).
- Sub-task granularity is preserved in git history.

### Per-sub-task validation chain

1. Agent executes the sub-task (just writes code, runs tests).
2. Symphony runs configured test command, checks exit code.
3. Symphony commits changes, pushes branch, opens stacked PR.
4. Review agent validates the work — specifically looking for corner-cutting, meaningless tests, hardcoded values, skipped requirements.
5. **Review agent should be a different model/provider than the executor** to avoid shared blind spots.

### Prompt construction — minimal

- Each executing agent receives the sub-task spec from the plan as its prompt. That's it.
- The agent has full workspace access and can explore the codebase itself.
- No elaborate prompt construction — no injected file contents, diffs, or context summaries.
- The workspace already contains previous sub-tasks' code (stacked branches), so context is implicit.

### Top-level task completion chain

Sub-task chain (agent → tests → PR → review agent) runs for each sub-task, then:
- Human reviews the full PR stack.
- Top-level task marked complete.

### Failure handling

- On sub-task failure: retry 1-2 times with error context injected.
- If retries exhausted: surface to human with failure details.
- Tune failure recovery based on real usage data, not upfront design.

### Configurable autonomy

Spectrum from full human oversight to full automation:
- Default: planning agent decomposes → human reviews plan → sequential execution with review agent → human reviews final PR stack.
- "Dangerously-skip-permissions": full automation, no human gates. Use carefully.

### Persistence

- Postgres via Ecto (Phoenix default, proper relational model for plans/tasks/dependencies/artifacts/users).
- Execution plans, tasks, dependencies, artifacts, agent runs, user accounts all persisted.
- Survives restarts — no re-running completed tasks.

### Authentication

- `mix phx.gen.auth` — Phoenix's built-in authentication system.
- Simple username/password. No OAuth needed for a small team.

### Notifications

- Dashboard only for now. No email/Slack integration in MVP.

### Workspace lifecycle

- Single workspace persists across the full execution plan.
- Symphony handles branch operations between sub-task runs.
- No per-sub-task workspace creation/teardown.

### Artifact detection

- Not needed as a separate concern. Since Symphony owns git operations, it knows exactly what changed (`git diff`), what branch was created, and what PR was opened — because it created them.
- Agent success determined by: clean exit code + test command passes.

### Relationship to existing codebase

- New Phoenix app within the existing repo (option b).
- Existing Linear-based Symphony remains functional as fallback.
- Shared modules cherry-picked where useful:
  - `Workspace` (per-task directory isolation, path safety)
  - Agent runner patterns (adapted from process-based to CLI/GenServer model)
- `Codex.AppServer` (JSON-RPC client) is **not reused** — replaced by uniform CLI execution via Safehouse.
- Core Orchestrator, Linear integration, in-memory state, WORKFLOW.md config are replaced by the new system.

## Data model (rough)

```
ExecutionPlan (1 per top-level task)
  ├── source: top-level task reference
  ├── status: planning | awaiting_review | executing | completed | failed
  └── tasks: ordered list of Task nodes

Task (sub-task)
  ├── spec: structured prompt context
  ├── position: order in sequence
  ├── agent_type: codex | claude_code | gemini | opencode | auto
  ├── status: pending | dispatched | running | testing | in_review | succeeded | failed
  ├── artifacts: %{branch, pr_url, files_changed, test_results}
  └── retry_state: attempt count, error context from previous attempts

User
  ├── basic account info
  └── team membership

TopLevelTask
  ├── title, description, relevant files/constraints
  ├── creator (user)
  ├── review_requested: boolean
  ├── reviewer (user, if review_requested)
  ├── execution_plan (has_one)
  └── status: draft | awaiting_review | planning | plan_review | executing | completed | failed
```

## What's deliberately deferred

- Multi-repo support
- Parallel top-level task execution (via git worktrees)
- Parallel sub-task execution
- Role-based permissions / approval chains
- Sophisticated failure recovery strategies
- Agent capability matching heuristics (start with explicit assignment, learn patterns later)
- Cost/token tracking
- Notifications beyond dashboard (Slack, email, webhooks)
- Agent-assisted merge conflict resolution

## Key architectural principles

- Simpler is better. Resist over-engineering.
- Human oversight is a feature, not a bottleneck.
- Sequential execution is a deliberate tradeoff for simplicity and correctness.
- Build for a small team, not enterprise scale.
- Tune based on real usage, not upfront speculation.
- Agents are CLI processes in sandboxes. Symphony owns git workflow and orchestration.
