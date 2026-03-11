defmodule SymphonyV2.Repo.Migrations.AddSingletonConstraintToAppSettings do
  use Ecto.Migration

  def up do
    alter table(:app_settings) do
      add :singleton, :boolean, default: true, null: false
    end

    create unique_index(:app_settings, [:singleton])

    execute """
    ALTER TABLE app_settings ADD CONSTRAINT app_settings_singleton_true CHECK (singleton = true)
    """
  end

  def down do
    execute "ALTER TABLE app_settings DROP CONSTRAINT IF EXISTS app_settings_singleton_true"
    drop_if_exists unique_index(:app_settings, [:singleton])

    alter table(:app_settings) do
      remove :singleton
    end
  end
end
