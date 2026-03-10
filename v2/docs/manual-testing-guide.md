# Manual Testing Guide — Symphony v2

Step-by-step instructions for testing Symphony v2 with real agents against a test repo.

## Prerequisites

1. **Elixir/Erlang**: Install via `mise trust && mise install` from the `v2/` directory
2. **PostgreSQL**: Running locally with default `postgres/postgres` credentials
3. **Agent CLIs**: Install at least one of:
   - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
   - [Codex](https://github.com/openai/codex) (`codex`)
   - [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`gemini`)
   - [Opencode](https://github.com/opencode-ai/opencode) (`opencode`)
4. **Agent Safehouse**: Install from [agent-safehouse.dev](https://agent-safehouse.dev/docs/)
5. **API Keys**: Set the appropriate environment variables:
   - `ANTHROPIC_API_KEY` for Claude Code
   - `OPENAI_API_KEY` for Codex
   - `GEMINI_API_KEY` for Gemini CLI

## Setup

```bash
cd v2/
mix setup          # deps, compile, create DB, migrate, seed
mix phx.server     # start at http://localhost:4000
```

Login with seed credentials: `admin@localhost` / `admin_password_123`

## Configure Settings

1. Navigate to **Settings** (`/app-settings`)
2. Edit configuration:
   - **Repo Path**: Path to a test git repository (create one with `git init`)
   - **Workspace Root**: Path where agent workspaces will be created (e.g., `/tmp/symphony-workspaces`)
   - **Test Command**: e.g., `mix test` or `echo 'tests pass'` for testing without real tests
   - **Planning Agent**: Select the agent to use for planning (Claude Code recommended)
   - **Review Agent**: Select a different agent for code review
   - **Default Agent**: Default agent for subtask execution

## Test Flow: Happy Path

### 1. Create a test repository

```bash
mkdir /tmp/test-repo && cd /tmp/test-repo
git init --initial-branch=main
echo "# Test Repo" > README.md
git add -A && git commit -m "init"
```

### 2. Create a task

- Navigate to **Tasks** → **New Task**
- Title: "Add a hello world module"
- Description: "Create a simple Elixir module with a `hello/0` function that returns `:world`"
- Leave "Request team review" unchecked
- Submit

### 3. Observe planning

- The pipeline picks up the task and runs the planning agent
- Watch the Dashboard for agent output streaming
- The planning agent writes `plan.json` to the workspace

### 4. Review the plan

- Navigate to the task's **Plan** page
- Review the subtask list
- Edit subtask specs or agent assignments if needed
- Click **Approve Plan**

### 5. Watch subtask execution

- Each subtask executes sequentially:
  1. Branch created
  2. Agent runs and writes code
  3. Tests run
  4. Changes committed and pushed
  5. PR created (if `gh` is configured)
  6. Review agent validates the work
- Monitor progress on the Dashboard

### 6. Final review

- After all subtasks complete, the task enters final review
- Navigate to **Stack Review** to see all PRs
- Click **Approve & Merge** or **Reject** with feedback

## Test Flow: Review Requested

1. Create a task with "Request team review" checked
2. Log in as a different user (create one via registration)
3. Navigate to the task and click "Approve Task"
4. The task proceeds to planning

## Test Flow: Plan Rejection

1. Create a task and wait for planning to complete
2. Review the plan and click "Reject & Re-plan"
3. The planning agent runs again with a new plan

## Test Flow: dangerously-skip-permissions

1. In Settings, enable "Dangerously Skip Permissions"
2. Create a task — it will run fully automatically:
   - Plan auto-approved
   - Final review auto-approved and merged
3. Disable the setting after testing

## Troubleshooting

- **Agent fails to start**: Check that the agent CLI is installed and in PATH
- **Safehouse errors**: Verify `safehouse` is installed and configured
- **Git errors**: Ensure the test repo has at least one commit on `main`
- **PR creation fails**: Configure `gh` CLI with `gh auth login`
- **Timeout**: Increase `agent_timeout_ms` in Settings
