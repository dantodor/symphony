defmodule SymphonyV2Web.TaskLive.Show do
  use SymphonyV2Web, :live_view

  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks
  alias SymphonyV2Web.PipelineErrors

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    task = Tasks.get_task!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))
    end

    plan = Plans.get_plan_by_task_id(task.id)

    {:ok,
     socket
     |> assign(:page_title, task.title)
     |> assign(:task, task)
     |> assign(:plan, plan)
     |> assign_subtask_subscriptions(plan)}
  end

  @impl true
  def handle_event("approve_review", _params, socket) do
    task = socket.assigns.task
    user = socket.assigns.current_scope.user

    case Tasks.approve_task_review(task, user) do
      {:ok, updated_task} ->
        notify_pipeline()

        {:noreply,
         socket
         |> assign(:task, Tasks.get_task!(updated_task.id))
         |> put_flash(:info, "Task approved and queued for planning.")}

      {:error, :self_review} ->
        {:noreply, put_flash(socket, :error, "You cannot approve your own task.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not approve task.")}
    end
  end

  def handle_event("approve_plan", _params, socket) do
    task = Tasks.get_task!(socket.assigns.task.id)

    if task.status == "plan_review" do
      case SymphonyV2.Pipeline.approve_plan() do
        :ok ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:info, "Plan approved. Execution started.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:error, PipelineErrors.format(reason))}
      end
    else
      {:noreply,
       socket
       |> reload_task()
       |> put_flash(:error, PipelineErrors.format(:not_awaiting_plan_review))}
    end
  end

  def handle_event("reject_plan", _params, socket) do
    task = Tasks.get_task!(socket.assigns.task.id)

    if task.status == "plan_review" do
      case SymphonyV2.Pipeline.reject_plan() do
        :ok ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:info, "Plan rejected. Re-planning...")}

        {:error, reason} ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:error, PipelineErrors.format(reason))}
      end
    else
      {:noreply,
       socket
       |> reload_task()
       |> put_flash(:error, PipelineErrors.format(:not_awaiting_plan_review))}
    end
  end

  def handle_event("approve_final", _params, socket) do
    task = Tasks.get_task!(socket.assigns.task.id)

    if task.status == "executing" do
      case SymphonyV2.Pipeline.approve_final() do
        :ok ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:info, "Final review approved. Merging...")}

        {:error, reason} ->
          {:noreply,
           socket
           |> reload_task()
           |> put_flash(:error, PipelineErrors.format(reason))}
      end
    else
      {:noreply,
       socket
       |> reload_task()
       |> put_flash(:error, PipelineErrors.format(:not_awaiting_final_review))}
    end
  end

  # PubSub handlers
  @impl true
  def handle_info({:task_step, _step}, socket) do
    {:noreply, reload_task(socket)}
  end

  def handle_info({:task_completed, _task_id}, socket) do
    {:noreply,
     socket
     |> reload_task()
     |> put_flash(:info, "Task completed successfully!")}
  end

  def handle_info({:task_failed, reason}, socket) do
    {:noreply,
     socket
     |> reload_task()
     |> put_flash(:error, "Task failed: #{PipelineErrors.format(reason)}")}
  end

  def handle_info({:subtask_started, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_running, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_testing, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_reviewing, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_succeeded, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_failed, _pos, _err}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_retrying, _pos, _count}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp notify_pipeline do
    SymphonyV2.Pipeline.check_queue()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp reload_task(socket) do
    task = Tasks.get_task!(socket.assigns.task.id)
    plan = Plans.get_plan_by_task_id(task.id)

    socket
    |> assign(:task, task)
    |> assign(:plan, plan)
    |> assign_subtask_subscriptions(plan)
  end

  defp reload_plan(socket) do
    plan = Plans.get_plan_by_task_id(socket.assigns.task.id)
    assign(socket, :plan, plan)
  end

  defp assign_subtask_subscriptions(socket, nil), do: socket

  defp assign_subtask_subscriptions(socket, plan) do
    if connected?(socket) do
      Enum.each(plan.subtasks, fn subtask ->
        Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.subtask(subtask.id))
      end)
    end

    socket
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

  defp subtask_status_class(status) do
    case status do
      "pending" -> "badge-ghost"
      "dispatched" -> "badge-info badge-outline"
      "running" -> "badge-info"
      "testing" -> "badge-warning"
      "in_review" -> "badge-secondary"
      "succeeded" -> "badge-success"
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

  defp can_approve_review?(task, current_user) do
    task.status == "awaiting_review" and task.creator_id != current_user.id
  end

  defp sorted_subtasks(plan) do
    plan.subtasks |> Enum.sort_by(& &1.position)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@task.title}
      <:subtitle>
        <span class={["badge", status_badge_class(@task.status)]}>
          {format_status(@task.status)}
        </span>
        <span class="ml-2 text-sm opacity-60">
          Created by {@task.creator && @task.creator.email} on {format_date(@task.inserted_at)}
        </span>
      </:subtitle>
      <:actions>
        <.button
          :if={can_approve_review?(@task, @current_scope.user)}
          phx-click="approve_review"
          variant="primary"
        >
          Approve Task
        </.button>
        <.button :if={@task.status == "plan_review"} phx-click="approve_plan" variant="primary">
          Approve Plan
        </.button>
        <.button :if={@task.status == "plan_review"} phx-click="reject_plan">
          Reject Plan
        </.button>
        <.button
          :if={@task.status == "completed" || @task.status == "executing"}
          navigate={~p"/tasks"}
        >
          Back
        </.button>
      </:actions>
    </.header>

    <%!-- Task Details --%>
    <div class="card bg-base-200 shadow-sm mt-4">
      <div class="card-body">
        <h3 class="card-title text-sm">Description</h3>
        <p class="whitespace-pre-wrap">{@task.description}</p>

        <div :if={@task.relevant_files && @task.relevant_files != ""} class="mt-4">
          <h3 class="font-semibold text-sm">Relevant Files</h3>
          <p class="whitespace-pre-wrap text-sm opacity-70">{@task.relevant_files}</p>
        </div>

        <div :if={@task.reviewer} class="mt-4">
          <h3 class="font-semibold text-sm">Reviewed by</h3>
          <p class="text-sm">{@task.reviewer.email}</p>
        </div>
      </div>
    </div>

    <%!-- Execution Plan --%>
    <div :if={@plan} class="mt-6">
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-semibold">Execution Plan</h2>
        <.link
          :if={@task.status == "plan_review"}
          navigate={~p"/tasks/#{@task}/plan"}
          class="btn btn-sm btn-outline btn-primary"
        >
          Edit Plan
        </.link>
      </div>
      <div class="overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th>#</th>
              <th>Title</th>
              <th>Agent</th>
              <th>Status</th>
              <th>PR</th>
              <th>Review</th>
              <th>Retries</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={subtask <- sorted_subtasks(@plan)}>
              <td>{subtask.position}</td>
              <td>
                <div class="font-medium">{subtask.title}</div>
                <div class="text-xs opacity-50 max-w-md truncate">{subtask.spec}</div>
              </td>
              <td>
                <span class="badge badge-sm badge-outline">{subtask.agent_type}</span>
              </td>
              <td>
                <span class={["badge badge-sm", subtask_status_class(subtask.status)]}>
                  {format_status(subtask.status)}
                </span>
              </td>
              <td>
                <a
                  :if={subtask.pr_url}
                  href={subtask.pr_url}
                  target="_blank"
                  class="link link-primary text-sm"
                >
                  PR #{subtask.pr_number}
                </a>
              </td>
              <td>
                <span
                  :if={subtask.review_verdict}
                  class={[
                    "badge badge-sm",
                    subtask.review_verdict == "approved" && "badge-success",
                    subtask.review_verdict == "rejected" && "badge-error"
                  ]}
                >
                  {subtask.review_verdict}
                </span>
              </td>
              <td>
                <span :if={subtask.retry_count && subtask.retry_count > 0} class="text-sm">
                  {subtask.retry_count}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <%!-- Final Review Actions --%>
    <div :if={@task.status == "executing" && @plan && all_subtasks_done?(@plan)} class="mt-6">
      <div class="alert alert-info">
        <span>All subtasks completed. Awaiting final review.</span>
        <.link navigate={~p"/tasks/#{@task}/stack-review"} class="btn btn-primary btn-sm">
          Review PR Stack
        </.link>
      </div>
    </div>

    <%!-- Error Display --%>
    <div :if={@task.status == "failed"} class="mt-6">
      <div class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>This task has failed. Check subtask details for error information.</span>
      </div>
      <div :if={failed_subtask_errors(@plan)} class="mt-2 card bg-base-200">
        <div class="card-body">
          <h3 class="card-title text-sm">Error Details</h3>
          <div :for={{subtask, error} <- failed_subtask_errors(@plan)} class="mb-2">
            <p class="font-medium text-sm">Step {subtask.position}: {subtask.title}</p>
            <pre class="text-xs bg-base-300 p-2 rounded mt-1 whitespace-pre-wrap">{error}</pre>
          </div>
        </div>
      </div>
    </div>

    <div class="mt-6">
      <.button navigate={~p"/tasks"}>Back to Tasks</.button>
    </div>
    """
  end

  defp all_subtasks_done?(nil), do: false

  defp all_subtasks_done?(plan) do
    Enum.all?(plan.subtasks, &(&1.status in ["succeeded", "failed"]))
  end

  defp failed_subtask_errors(nil), do: nil

  defp failed_subtask_errors(plan) do
    errors =
      plan.subtasks
      |> Enum.filter(&(&1.status == "failed" && &1.last_error))
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&{&1, &1.last_error})

    if errors == [], do: nil, else: errors
  end
end
