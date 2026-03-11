defmodule SymphonyV2.Repo.Migrations.AddPlanReviewStatusToExecutionPlans do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE execution_plans DROP CONSTRAINT IF EXISTS execution_plans_status_check"

    execute """
    ALTER TABLE execution_plans ADD CONSTRAINT execution_plans_status_check
    CHECK (status IN ('planning', 'awaiting_review', 'plan_review', 'executing', 'completed', 'failed'))
    """
  end

  def down do
    execute "ALTER TABLE execution_plans DROP CONSTRAINT IF EXISTS execution_plans_status_check"
  end
end
