defmodule SymphonyV2.TasksFixtures do
  @moduledoc """
  Test helpers for creating entities via the `SymphonyV2.Tasks` context.
  """

  alias SymphonyV2.AccountsFixtures
  alias SymphonyV2.Tasks

  def valid_task_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      title: "Task #{System.unique_integer([:positive])}",
      description: "A test task description with enough detail.",
      relevant_files: "lib/some_module.ex",
      review_requested: false
    })
  end

  def task_fixture(attrs \\ %{}) do
    creator = Map.get_lazy(attrs, :creator, fn -> AccountsFixtures.user_fixture() end)
    attrs = Map.delete(attrs, :creator)

    {:ok, task} =
      attrs
      |> valid_task_attributes()
      |> Tasks.create_task(creator)

    task
  end
end
