# Plan File Format

The planning agent writes a `plan.json` file to the workspace root after analyzing the codebase and decomposing a task into ordered subtasks.

## Schema

```json
{
  "tasks": [
    {
      "position": 1,
      "title": "Short description of the subtask",
      "spec": "Detailed specification of what the agent should implement...",
      "agent_type": "claude_code"
    },
    {
      "position": 2,
      "title": "Next subtask",
      "spec": "Detailed specification...",
      "agent_type": "codex"
    }
  ]
}
```

## Field Definitions

### Root Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `tasks` | array | Yes | Ordered list of subtask objects. Must contain at least one entry. |

### Subtask Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `position` | integer | Yes | 1-based sequential position. Must be unique and sequential starting from 1. |
| `title` | string | Yes | Short, descriptive title for the subtask. Non-empty. |
| `spec` | string | Yes | Detailed specification of what the agent should implement. Non-empty. |
| `agent_type` | string | Yes | The coding agent to use. Must be a registered agent type. |

## Valid Agent Types

- `claude_code` — Anthropic Claude Code (Opus-tier)
- `codex` — OpenAI Codex CLI
- `gemini_cli` — Google Gemini CLI
- `opencode` — Opencode CLI

Custom agents registered via application configuration are also valid.

## Validation Rules

1. The root object must contain a `tasks` array
2. `tasks` must contain at least one entry
3. All `position` values must be sequential integers starting from 1 (1, 2, 3, ...)
4. All `agent_type` values must reference a registered agent in the AgentRegistry
5. `title` and `spec` must be non-empty strings
6. No duplicate positions are allowed

## Example

```json
{
  "tasks": [
    {
      "position": 1,
      "title": "Design auth schema and migrations",
      "spec": "Create an Ecto migration for user authentication. Add a users table with email, password_hash, and timestamps. Create the corresponding Ecto schema with changesets for registration and login.",
      "agent_type": "claude_code"
    },
    {
      "position": 2,
      "title": "Implement auth context",
      "spec": "Create an Accounts context module with functions for user registration, authentication, and session management. Use bcrypt for password hashing.",
      "agent_type": "claude_code"
    },
    {
      "position": 3,
      "title": "Add auth plugs and routes",
      "spec": "Create Phoenix plugs for authentication and authorization. Update the router to protect routes requiring authentication.",
      "agent_type": "codex"
    }
  ]
}
```
