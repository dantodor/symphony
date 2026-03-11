defmodule SymphonyV2.Repo.Migrations.AddPipelinePausedToAppSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :pipeline_paused, :boolean, default: false, null: false
    end
  end
end
