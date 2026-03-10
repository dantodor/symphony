# Symphony v2

A self-contained orchestration system that decomposes high-level tasks into ordered subtasks, dispatches coding agents (Claude Code, Codex, Gemini CLI, Opencode) to execute them sequentially, and manages the full git lifecycle including stacked PRs.

## Key Features

- **Multi-agent dispatch**: Pick the best coding agent for each subtask
- **Agent sandboxing**: All agents run inside [Agent Safehouse](https://agent-safehouse.dev/) for kernel-level isolation
- **Human-agent collaborative planning**: AI planning agent decomposes tasks, humans review and edit plans
- **Sequential execution**: One task at a time, subtasks execute in order with stacked branches
- **Automated validation**: Test runner + review agent (different model) validates each subtask
- **Real-time monitoring**: LiveView dashboard with agent output streaming
- **Configurable autonomy**: From full human oversight to fully automated (`dangerously-skip-permissions`)

## Architecture

Phoenix LiveView app with Ecto/Postgres. Core components:

- **Pipeline** — GenServer orchestrating the full lifecycle: planning → plan review → subtask execution → testing → review → final review → merge
- **AgentProcess** — GenServer managing individual CLI agent processes via Erlang ports
- **Workspace** — Per-task directory isolation with git clone
- **GitOps** — Branch creation, stacked PRs, rebase, merge
- **Safehouse** — CLI command builder for sandboxed agent execution

## Setup

```bash
cd v2/
mise trust && mise install   # Erlang/Elixir toolchain
mix setup                    # deps, compile, create DB, migrate, seed
mix phx.server               # start at http://localhost:4000
```

Login: `admin@localhost` / `admin_password_123`

## Development

```bash
make test       # run tests
make coverage   # run tests with coverage (88% threshold)
make lint       # credo strict
make all        # full quality gate (compile, format, lint, coverage, dialyzer)
```

## Documentation

- [Design Brainstorm](../docs/v2-design-brainstorm.md) — architectural decisions and rationale
- [Implementation Plan](../docs/v2-implementation-plan.md) — phased build plan (220 steps)
- [Plan File Format](../docs/plan-file-format.md) — JSON schema for agent-generated plans
- [Manual Testing Guide](docs/manual-testing-guide.md) — testing with real agents
