defmodule SymphonyV2.Repo.Migrations.AddReviewFailureActionToAppSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :review_failure_action, :string, default: "auto_approve", null: false
    end
  end
end
