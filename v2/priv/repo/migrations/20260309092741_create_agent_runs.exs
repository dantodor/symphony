defmodule SymphonyV2.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :subtask_id, references(:subtasks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_type, :string, null: false
      add :attempt_number, :integer, null: false
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :exit_code, :integer
      add :stdout_log_path, :string
      add :stderr_log_path, :string
      add :duration_ms, :integer
      add :error_message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:subtask_id])
    create index(:agent_runs, [:status])
  end
end
