defmodule SymphonyV2.Repo.Migrations.AddTasksStatusQueuePositionIndex do
  use Ecto.Migration

  def change do
    create index(:tasks, [:status, :queue_position])
  end
end
