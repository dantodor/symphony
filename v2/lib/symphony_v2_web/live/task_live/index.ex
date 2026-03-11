defmodule SymphonyV2Web.TaskLive.Index do
  use SymphonyV2Web, :live_view

  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks

  @status_filters ~w(all queued in_progress completed failed)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.pipeline())
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.tasks())
    end

    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:status_filter, "all")
     |> assign(:status_filters, @status_filters)
     |> assign_tasks()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter = Map.get(params, "status", "all")

    filter =
      if filter in @status_filters, do: filter, else: "all"

    {:noreply,
     socket
     |> assign(:status_filter, filter)
     |> assign_tasks()}
  end

  @impl true
  def handle_info({:pipeline_started, _task_id}, socket) do
    {:noreply, assign_tasks(socket)}
  end

  def handle_info({:pipeline_idle, _task_id}, socket) do
    {:noreply, assign_tasks(socket)}
  end

  def handle_info({:task_status_changed, _task_id, _status}, socket) do
    {:noreply, assign_tasks(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_tasks(socket) do
    tasks =
      case socket.assigns.status_filter do
        "all" ->
          Tasks.list_tasks()

        "queued" ->
          Tasks.list_tasks_by_status("draft") ++
            Tasks.list_tasks_by_status("awaiting_review") ++
            Tasks.list_tasks_by_status("planning")

        "in_progress" ->
          Tasks.list_tasks_by_status("plan_review") ++ Tasks.list_tasks_by_status("executing")

        "completed" ->
          Tasks.list_tasks_by_status("completed")

        "failed" ->
          Tasks.list_tasks_by_status("failed")

        _ ->
          Tasks.list_tasks()
      end

    assign(socket, :tasks, tasks)
  end

  defp status_badge_class(status) do
    case status do
      "draft" -> "badge-ghost"
      "awaiting_review" -> "badge-warning"
      "planning" -> "badge-info"
      "plan_review" -> "badge-info"
      "executing" -> "badge-info"
      "completed" -> "badge-success"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_status(status) do
    status
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Tasks
      <:actions>
        <.button navigate={~p"/tasks/new"} variant="primary">New Task</.button>
      </:actions>
    </.header>

    <div role="tablist" class="tabs tabs-border mb-6">
      <.link
        :for={filter <- @status_filters}
        patch={~p"/tasks?#{%{status: filter}}"}
        class={["tab", @status_filter == filter && "tab-active"]}
      >
        {format_status(filter)}
      </.link>
    </div>

    <div :if={@tasks == []} class="text-center py-12 text-base-content/50">
      No tasks found.
    </div>

    <.table :if={@tasks != []} id="tasks" rows={@tasks} row_click={&JS.navigate(~p"/tasks/#{&1}")}>
      <:col :let={task} label="Title">{task.title}</:col>
      <:col :let={task} label="Status">
        <span class={["badge badge-sm", status_badge_class(task.status)]}>
          {format_status(task.status)}
        </span>
      </:col>
      <:col :let={task} label="Creator">{task.creator && task.creator.email}</:col>
      <:col :let={task} label="Created">{format_date(task.inserted_at)}</:col>
      <:col :let={task} label="Queue">
        {task.queue_position}
      </:col>
    </.table>
    """
  end
end
