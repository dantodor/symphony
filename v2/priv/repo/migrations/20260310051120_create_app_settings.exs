defmodule SymphonyV2.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :test_command, :string, default: "mix test"
      add :planning_agent, :string, default: "claude_code"
      add :review_agent, :string, default: "gemini_cli"
      add :default_agent, :string, default: "claude_code"
      add :dangerously_skip_permissions, :boolean, default: false
      add :agent_timeout_ms, :integer, default: 600_000
      add :max_retries, :integer, default: 2

      timestamps(type: :utc_datetime)
    end

    create table(:custom_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :command, :string, null: false
      add :prompt_flag, :string, null: false
      add :skip_permissions_flag, :string
      add :env_vars, {:array, :string}, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:custom_agents, [:name])
  end
end
