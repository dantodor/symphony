# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Symphony is a long-running orchestration service that polls Linear for issues, creates isolated per-issue workspaces, and dispatches Codex coding agents autonomously. The language-agnostic specification lives in `SPEC.md`; the reference implementation is in `elixir/`.

## Build & Development Commands

All commands run from the `elixir/` directory. Toolchain: Elixir 1.19.x / OTP 28 via `mise`.

```bash
# Setup
mise trust && mise install && mix setup

# Build escript
mix build                  # produces bin/symphony

# Run
./bin/symphony ./WORKFLOW.md [--logs-root <dir>] [--port <num>]

# Format
mix format                 # auto-format
mix format --check-formatted  # check only

# Lint
mix lint                   # runs specs.check + credo --strict

# Test
mix test                   # all tests
mix test test/symphony_elixir/core_test.exs          # single file
mix test test/symphony_elixir/core_test.exs:42       # single test by line

# Coverage (100% threshold enforced)
mix test --cover

# Dialyzer (static type analysis)
mix dialyzer --format short

# Full quality gate (CI runs this)
make all                   # = setup, build, fmt-check, lint, coverage, dialyzer

# PR body validation
mix pr_body.check --file /path/to/pr_body.md

# Spec annotation check
mix specs.check
```

## Architecture

**OTP Application** with supervisor tree: TaskSupervisor → PubSub → WorkflowStore → Orchestrator → HttpServer → StatusDashboard.

### Core Loop
- **Orchestrator** (`lib/symphony_elixir/orchestrator.ex`): GenServer polling Linear on a fixed cadence. Maintains in-memory state for running agents, completed issues, and retries with exponential backoff. Dispatches up to `max_concurrent_agents` concurrent agent runs.
- **AgentRunner** (`lib/symphony_elixir/agent_runner.ex`): Creates an isolated workspace per issue, builds a prompt from the issue + WORKFLOW.md template, launches Codex, and streams updates back to the Orchestrator.
- **Codex.AppServer** (`lib/symphony_elixir/codex/app_server.ex`): JSON-RPC 2.0 client for Codex app-server protocol. Manages session lifecycle and token accounting.

### Configuration
- **Config** (`lib/symphony_elixir/config.ex`): Typed runtime config parsed from `WORKFLOW.md` YAML front matter via `SymphonyElixir.Workflow`. Prefer adding config access through this module instead of ad-hoc env reads.
- **WorkflowStore** (`lib/symphony_elixir/workflow_store.ex`): Watches and hot-reloads WORKFLOW.md changes.

### Integration
- **Linear.Client** (`lib/symphony_elixir/linear/client.ex`): GraphQL client for Linear API.
- **Linear.Adapter** (`lib/symphony_elixir/linear/adapter.ex`): Implements the `SymphonyElixir.Tracker` behaviour (pluggable tracker abstraction).

### Observability (optional, `--port` flag)
- Phoenix LiveView dashboard at `/`, JSON API at `/api/v1/state`, `/api/v1/<issue_identifier>`, `/api/v1/refresh`.
- **StatusDashboard** broadcasts via PubSub; **DashboardLive** renders real-time updates.

### Workspace Management
- **Workspace** (`lib/symphony_elixir/workspace.ex`): Per-issue directory creation/cleanup with path validation (must stay under workspace root). Supports after_create/before_remove hooks.

## Required Conventions

- **Public functions** (`def`) in `lib/` must have an adjacent `@spec`. `defp` specs are optional. `@impl` callbacks are exempt.
- **Logging**: Include `issue_id` + `issue_identifier` for issue-related logs, `session_id` for Codex execution events (see `docs/logging.md`).
- **Workspace safety**: Never run Codex with cwd in the source repo. Workspaces must stay under the configured workspace root.
- **Spec alignment**: Implementation must not conflict with `SPEC.md`. If behavior changes meaningfully, update the spec in the same PR.
- Keep changes narrowly scoped; avoid unrelated refactors. Follow existing module/style patterns.

## Docs Update Policy

If behavior or config changes, update in the same PR:
- `README.md` for project concept/goals
- `elixir/WORKFLOW.md` for workflow/config contract
- `SPEC.md` if implementation changes alter intended behavior
