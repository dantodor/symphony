defmodule SymphonyV2.Repo.Migrations.ChangeAgentRunsSubtaskFkToNilify do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE agent_runs DROP CONSTRAINT IF EXISTS agent_runs_subtask_id_fkey"

    execute "ALTER TABLE agent_runs ALTER COLUMN subtask_id DROP NOT NULL"

    execute """
    ALTER TABLE agent_runs
    ADD CONSTRAINT agent_runs_subtask_id_fkey
    FOREIGN KEY (subtask_id) REFERENCES subtasks(id) ON DELETE SET NULL
    """
  end

  def down do
    execute "ALTER TABLE agent_runs DROP CONSTRAINT IF EXISTS agent_runs_subtask_id_fkey"

    execute "UPDATE agent_runs SET subtask_id = NULL WHERE subtask_id IS NULL"
    execute "ALTER TABLE agent_runs ALTER COLUMN subtask_id SET NOT NULL"

    execute """
    ALTER TABLE agent_runs
    ADD CONSTRAINT agent_runs_subtask_id_fkey
    FOREIGN KEY (subtask_id) REFERENCES subtasks(id) ON DELETE CASCADE
    """
  end
end
