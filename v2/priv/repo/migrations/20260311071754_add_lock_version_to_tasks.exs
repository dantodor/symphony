defmodule SymphonyV2.Repo.Migrations.AddLockVersionToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :lock_version, :integer, default: 1, null: false
    end
  end
end
