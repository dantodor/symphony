defmodule SymphonyV2.Repo.Migrations.CreateSubtasks do
  use Ecto.Migration

  def change do
    create table(:subtasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :execution_plan_id,
          references(:execution_plans, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :title, :string, null: false
      add :spec, :text, null: false
      add :agent_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :branch_name, :string
      add :pr_url, :string
      add :pr_number, :integer
      add :commit_sha, :string
      add :files_changed, {:array, :string}
      add :test_output, :text
      add :test_passed, :boolean
      add :review_verdict, :string
      add :review_reasoning, :text
      add :retry_count, :integer, null: false, default: 0
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:subtasks, [:execution_plan_id])
    create index(:subtasks, [:status])
    create unique_index(:subtasks, [:execution_plan_id, :position])
  end
end
