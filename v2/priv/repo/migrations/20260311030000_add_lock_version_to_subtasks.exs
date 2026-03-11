defmodule SymphonyV2.Repo.Migrations.AddLockVersionToSubtasks do
  use Ecto.Migration

  def change do
    alter table(:subtasks) do
      add :lock_version, :integer, default: 1, null: false
    end
  end
end
