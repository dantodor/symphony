defmodule SymphonyV2.Repo.Migrations.CreateExecutionPlans do
  use Ecto.Migration

  def change do
    create table(:execution_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "planning"
      add :raw_plan, :map
      add :plan_file_path, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:execution_plans, [:task_id])
    create index(:execution_plans, [:status])
  end
end
