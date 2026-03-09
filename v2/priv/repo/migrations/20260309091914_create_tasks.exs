defmodule SymphonyV2.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text, null: false
      add :relevant_files, :text
      add :status, :string, null: false, default: "draft"
      add :review_requested, :boolean, null: false, default: false
      add :creator_id, references(:users, on_delete: :restrict), null: false
      add :reviewer_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :queue_position, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:creator_id])
    create index(:tasks, [:reviewer_id])
    create index(:tasks, [:status])
    create index(:tasks, [:queue_position])
  end
end
