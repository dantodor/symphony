defmodule SymphonyV2Web.TaskLive.New do
  use SymphonyV2Web, :live_view

  alias SymphonyV2.Tasks
  alias SymphonyV2.Tasks.Task

  @impl true
  def mount(_params, _session, socket) do
    changeset = Tasks.change_task(%Task{})

    {:ok,
     socket
     |> assign(:page_title, "New Task")
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"task" => task_params}, socket) do
    changeset =
      %Task{}
      |> Tasks.change_task(task_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"task" => task_params}, socket) do
    user = socket.assigns.current_scope.user

    case Tasks.create_task(task_params, user) do
      {:ok, task} ->
        # If review not requested, transition directly to planning and notify pipeline
        socket =
          if task.review_requested do
            {:ok, _} = Tasks.update_task_status(task, "awaiting_review")

            socket
            |> put_flash(:info, "Task created. Awaiting review.")
            |> push_navigate(to: ~p"/tasks/#{task}")
          else
            {:ok, task} = Tasks.update_task_status(task, "planning")
            notify_pipeline()

            socket
            |> put_flash(:info, "Task created and queued for planning.")
            |> push_navigate(to: ~p"/tasks/#{task}")
          end

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp notify_pipeline do
    SymphonyV2.Pipeline.check_queue()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      New Task
      <:subtitle>Create a new task for agent execution.</:subtitle>
    </.header>

    <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" class="space-y-4">
      <.input
        field={@form[:title]}
        type="text"
        label="Title"
        required
        placeholder="e.g. Add user avatar upload"
      />
      <.input
        field={@form[:description]}
        type="textarea"
        label="Description"
        required
        rows="6"
        placeholder="Describe what needs to be done..."
      />
      <.input
        field={@form[:relevant_files]}
        type="textarea"
        label="Relevant files / constraints (optional)"
        rows="3"
        placeholder="e.g. lib/my_app/accounts.ex, test/my_app/accounts_test.exs"
      />
      <.input
        field={@form[:review_requested]}
        type="checkbox"
        label="Request team review before automation starts"
      />

      <div class="flex gap-4 pt-4">
        <.button type="submit" variant="primary">Create Task</.button>
        <.button navigate={~p"/tasks"}>Cancel</.button>
      </div>
    </.form>
    """
  end
end
