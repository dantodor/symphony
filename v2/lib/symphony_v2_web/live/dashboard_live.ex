defmodule SymphonyV2Web.DashboardLive do
  @moduledoc """
  Real-time execution monitoring dashboard.

  Shows pipeline status, current task progress, subtask execution details,
  live agent output streaming, task queue, and manual controls.
  """

  use SymphonyV2Web, :live_view

  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks
  alias SymphonyV2Web.PipelineErrors

  @max_output_lines 500

  @impl true
  def mount(_params, _session, socket) do
    pipeline_state = get_pipeline_state()
    {task, plan} = load_current_task(pipeline_state)
    queued_tasks = Tasks.list_queued_tasks()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.pipeline())

      if task do
        Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))
        subscribe_to_subtasks(plan)
        maybe_subscribe_to_agent_output(socket, pipeline_state, plan)
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:pipeline_state, pipeline_state)
     |> assign(:task, task)
     |> assign(:plan, plan)
     |> assign(:queued_tasks, queued_tasks)
     |> assign(:expanded_subtask_id, nil)
     |> assign(:agent_output, [])
     |> assign(:agent_run_id, nil)}
  end

  # --- Event handlers ---

  @impl true
  def handle_event("pause", _params, socket) do
    SymphonyV2.Pipeline.pause()
    {:noreply, socket}
  end

  def handle_event("resume", _params, socket) do
    SymphonyV2.Pipeline.resume()
    {:noreply, socket}
  end

  def handle_event("retry_task", _params, socket) do
    case SymphonyV2.Pipeline.retry_task() do
      :ok ->
        {:noreply, put_flash(socket, :info, "Retrying failed task...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PipelineErrors.format(reason))}
    end
  end

  def handle_event("approve_plan", _params, socket) do
    case SymphonyV2.Pipeline.approve_plan() do
      :ok ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, "Plan approved. Execution started.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:error, PipelineErrors.format(reason))}
    end
  end

  def handle_event("reject_plan", _params, socket) do
    case SymphonyV2.Pipeline.reject_plan() do
      :ok ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, "Plan rejected. Re-planning...")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:error, PipelineErrors.format(reason))}
    end
  end

  def handle_event("approve_final", _params, socket) do
    case SymphonyV2.Pipeline.approve_final() do
      :ok ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, "Final review approved. Merging...")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:error, PipelineErrors.format(reason))}
    end
  end

  def handle_event("toggle_subtask", %{"id" => id}, socket) do
    current = socket.assigns.expanded_subtask_id

    {:noreply, assign(socket, :expanded_subtask_id, if(current == id, do: nil, else: id))}
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:pipeline_started, _task_id}, socket) do
    {:noreply, reload_state(socket)}
  end

  def handle_info({:pipeline_idle, _task_id}, socket) do
    {:noreply,
     socket
     |> reload_state()
     |> assign(:agent_output, [])
     |> assign(:agent_run_id, nil)}
  end

  def handle_info({:pipeline_paused, _task_id}, socket) do
    {:noreply, reload_state(socket)}
  end

  def handle_info({:pipeline_resumed, _task_id}, socket) do
    {:noreply, reload_state(socket)}
  end

  def handle_info({:task_step, _step}, socket) do
    {:noreply, reload_state(socket)}
  end

  def handle_info({:task_completed, _task_id}, socket) do
    {:noreply,
     socket
     |> reload_state()
     |> put_flash(:info, "Task completed successfully!")}
  end

  def handle_info({:task_failed, reason}, socket) do
    {:noreply,
     socket
     |> reload_state()
     |> put_flash(:error, "Task failed: #{PipelineErrors.format(reason)}")}
  end

  def handle_info({:subtask_started, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_testing, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_reviewing, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_succeeded, _pos}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_failed, _pos, _err}, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:subtask_retrying, _pos, _count}, socket), do: {:noreply, reload_plan(socket)}

  def handle_info({:subtask_running, _pos}, socket) do
    # A new agent started running — find its agent_run_id and subscribe to output
    socket = reload_plan(socket)
    pipeline_state = get_pipeline_state()

    socket =
      socket
      |> assign(:pipeline_state, pipeline_state)
      |> assign(:agent_output, [])

    socket = subscribe_to_current_agent(socket, pipeline_state, socket.assigns.plan)
    {:noreply, socket}
  end

  def handle_info({:agent_output, _agent_run_id, text}, socket) do
    lines = socket.assigns.agent_output
    new_lines = String.split(text, "\n", trim: false)
    combined = (lines ++ new_lines) |> Enum.take(-@max_output_lines)
    {:noreply, assign(socket, :agent_output, combined)}
  end

  def handle_info({:agent_complete, _agent_run_id, _result}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  defp get_pipeline_state do
    SymphonyV2.Pipeline.get_state()
  rescue
    _ ->
      %{
        status: :idle,
        current_task_id: nil,
        current_subtask_id: nil,
        current_step: nil,
        paused: false
      }
  catch
    :exit, _ ->
      %{
        status: :idle,
        current_task_id: nil,
        current_subtask_id: nil,
        current_step: nil,
        paused: false
      }
  end

  defp load_current_task(%{current_task_id: task_id}) when not is_nil(task_id) do
    task = Tasks.get_task!(task_id)
    plan = Plans.get_plan_by_task_id(task_id)
    {task, plan}
  rescue
    _ -> load_active_task_from_db()
  end

  defp load_current_task(_), do: load_active_task_from_db()

  defp load_active_task_from_db do
    # Check for in-progress tasks in the DB (useful when pipeline state is not yet synced)
    ~w(executing plan_review planning)
    |> Enum.find_value(fn status ->
      case Tasks.list_tasks_by_status(status) do
        [task | _] -> {task, Plans.get_plan_by_task_id(task.id)}
        [] -> nil
      end
    end)
    |> case do
      nil -> {nil, nil}
      result -> result
    end
  rescue
    _ -> {nil, nil}
  end

  defp reload_state(socket) do
    pipeline_state = get_pipeline_state()
    {task, plan} = load_current_task(pipeline_state)
    queued_tasks = Tasks.list_queued_tasks()

    # Subscribe to new task/subtask topics if task changed
    if connected?(socket) && task != nil &&
         task.id != (socket.assigns.task && socket.assigns.task.id) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))
      subscribe_to_subtasks(plan)
    end

    socket
    |> assign(:pipeline_state, pipeline_state)
    |> assign(:task, task)
    |> assign(:plan, plan)
    |> assign(:queued_tasks, queued_tasks)
  end

  defp reload_plan(socket) do
    case socket.assigns.task do
      nil ->
        socket

      task ->
        plan = Plans.get_plan_by_task_id(task.id)
        assign(socket, :plan, plan)
    end
  end

  defp subscribe_to_subtasks(nil), do: :ok

  defp subscribe_to_subtasks(plan) do
    Enum.each(plan.subtasks, fn subtask ->
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.subtask(subtask.id))
    end)
  end

  defp maybe_subscribe_to_agent_output(socket, pipeline_state, plan) do
    subscribe_to_current_agent(socket, pipeline_state, plan)
  end

  defp subscribe_to_current_agent(socket, %{current_subtask_id: nil}, _plan), do: socket
  defp subscribe_to_current_agent(socket, _pipeline_state, nil), do: socket

  defp subscribe_to_current_agent(socket, %{current_subtask_id: subtask_id}, _plan) do
    case Plans.latest_agent_run_for_subtask(subtask_id) do
      nil ->
        socket

      agent_run ->
        if agent_run.id != socket.assigns.agent_run_id do
          Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.agent_output(agent_run.id))
          assign(socket, :agent_run_id, agent_run.id)
        else
          socket
        end
    end
  end

  defp sorted_subtasks(nil), do: []
  defp sorted_subtasks(plan), do: plan.subtasks |> Enum.sort_by(& &1.position)

  defp step_label(nil), do: "Idle"
  defp step_label(:planning), do: "Planning"
  defp step_label(:awaiting_plan_review), do: "Awaiting Plan Review"
  defp step_label(:executing_subtask), do: "Executing Subtask"
  defp step_label(:testing), do: "Running Tests"
  defp step_label(:reviewing), do: "Code Review"
  defp step_label(:awaiting_final_review), do: "Awaiting Final Review"
  defp step_label(:merging), do: "Merging"
  defp step_label(:paused), do: "Paused"
  defp step_label(_), do: "Unknown"

  defp step_badge_class(nil), do: "badge-ghost"
  defp step_badge_class(:planning), do: "badge-info"
  defp step_badge_class(:awaiting_plan_review), do: "badge-warning"
  defp step_badge_class(:executing_subtask), do: "badge-info"
  defp step_badge_class(:testing), do: "badge-warning"
  defp step_badge_class(:reviewing), do: "badge-secondary"
  defp step_badge_class(:awaiting_final_review), do: "badge-warning"
  defp step_badge_class(:merging), do: "badge-accent"
  defp step_badge_class(:paused), do: "badge-warning"
  defp step_badge_class(_), do: "badge-ghost"

  defp subtask_status_icon(status) do
    case status do
      "pending" -> "hero-clock"
      "dispatched" -> "hero-arrow-right-circle"
      "running" -> "hero-cog-6-tooth"
      "testing" -> "hero-beaker"
      "in_review" -> "hero-magnifying-glass"
      "succeeded" -> "hero-check-circle"
      "failed" -> "hero-x-circle"
      _ -> "hero-question-mark-circle"
    end
  end

  defp subtask_status_color(status) do
    case status do
      "pending" -> "text-base-content/40"
      "dispatched" -> "text-info"
      "running" -> "text-info animate-spin"
      "testing" -> "text-warning"
      "in_review" -> "text-secondary"
      "succeeded" -> "text-success"
      "failed" -> "text-error"
      _ -> "text-base-content/40"
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

  defp task_status_badge_class(status) do
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

  defp progress_percentage(plan) do
    subtasks = sorted_subtasks(plan)

    case length(subtasks) do
      0 ->
        0

      total ->
        done = Enum.count(subtasks, &(&1.status == "succeeded"))
        round(done / total * 100)
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6">
      <%!-- Main content --%>
      <div class="flex-1 min-w-0">
        <%!-- Pipeline Status --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body py-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <h2 class="card-title text-base">Pipeline Status</h2>
                <span
                  :if={@pipeline_state.status == :idle}
                  class="badge badge-ghost"
                >
                  Idle
                </span>
                <span
                  :if={@pipeline_state.status == :processing && !@pipeline_state[:paused]}
                  class={["badge", step_badge_class(@pipeline_state.current_step)]}
                >
                  {step_label(@pipeline_state.current_step)}
                </span>
                <span
                  :if={@pipeline_state[:paused]}
                  class="badge badge-warning"
                >
                  Paused
                </span>
              </div>
              <%!-- Controls --%>
              <div class="flex gap-2">
                <button
                  :if={@pipeline_state.status == :processing && !@pipeline_state[:paused]}
                  phx-click="pause"
                  class="btn btn-sm btn-warning btn-outline"
                >
                  <.icon name="hero-pause" class="size-4" /> Pause
                </button>
                <button
                  :if={@pipeline_state[:paused]}
                  phx-click="resume"
                  class="btn btn-sm btn-success btn-outline"
                >
                  <.icon name="hero-play" class="size-4" /> Resume
                </button>
                <button
                  :if={@pipeline_state.status == :idle && has_failed_task?(@queued_tasks, @task)}
                  phx-click="retry_task"
                  class="btn btn-sm btn-info btn-outline"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Retry Failed
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Current Task --%>
        <div :if={@task} class="card bg-base-200 shadow-sm mt-4">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="card-title text-base">
                  <.link navigate={~p"/tasks/#{@task}"} class="link link-hover">
                    {@task.title}
                  </.link>
                </h3>
                <p class="text-sm opacity-70 mt-1 line-clamp-2">{@task.description}</p>
              </div>
              <div class="flex gap-2">
                <button
                  :if={
                    @pipeline_state.current_step == :awaiting_plan_review ||
                      @task.status == "plan_review"
                  }
                  phx-click="approve_plan"
                  class="btn btn-sm btn-success"
                >
                  Approve Plan
                </button>
                <button
                  :if={
                    @pipeline_state.current_step == :awaiting_plan_review ||
                      @task.status == "plan_review"
                  }
                  phx-click="reject_plan"
                  class="btn btn-sm btn-error btn-outline"
                >
                  Reject Plan
                </button>
                <button
                  :if={@pipeline_state.current_step == :awaiting_final_review}
                  phx-click="approve_final"
                  class="btn btn-sm btn-success"
                >
                  Approve & Merge
                </button>
              </div>
            </div>

            <%!-- Progress bar --%>
            <div :if={@plan} class="mt-3">
              <div class="flex justify-between text-xs mb-1">
                <span>Progress</span>
                <span>{progress_percentage(@plan)}%</span>
              </div>
              <progress
                class="progress progress-primary w-full"
                value={progress_percentage(@plan)}
                max="100"
              >
              </progress>
            </div>
          </div>
        </div>

        <div :if={!@task && @pipeline_state.status == :idle} class="card bg-base-200 shadow-sm mt-4">
          <div class="card-body py-6 text-center opacity-60">
            <p>No task is currently being processed.</p>
            <.link navigate={~p"/tasks/new"} class="btn btn-sm btn-primary mt-2">
              Create Task
            </.link>
          </div>
        </div>

        <%!-- Subtask Progress --%>
        <div :if={@plan} class="mt-4">
          <h3 class="text-base font-semibold mb-2">Subtasks</h3>
          <div class="space-y-2">
            <div :for={subtask <- sorted_subtasks(@plan)} class="card bg-base-200 shadow-sm">
              <div
                class="card-body py-3 px-4 cursor-pointer"
                phx-click="toggle_subtask"
                phx-value-id={subtask.id}
              >
                <div class="flex items-center gap-3">
                  <%!-- Status icon --%>
                  <.icon
                    name={subtask_status_icon(subtask.status)}
                    class={["size-5", subtask_status_color(subtask.status)]}
                  />
                  <%!-- Position and title --%>
                  <span class="text-sm font-mono opacity-50">{subtask.position}</span>
                  <span class="font-medium flex-1">{subtask.title}</span>
                  <%!-- Agent type --%>
                  <span class="badge badge-sm badge-outline">{subtask.agent_type}</span>
                  <%!-- Status badge --%>
                  <span class={["badge badge-sm", subtask_status_class(subtask.status)]}>
                    {format_status(subtask.status)}
                  </span>
                  <%!-- PR link --%>
                  <a
                    :if={subtask.pr_url}
                    href={subtask.pr_url}
                    target="_blank"
                    class="link link-primary text-sm"
                    phx-click={Phoenix.LiveView.JS.dispatch("phx:stop-propagation")}
                  >
                    PR #{subtask.pr_number}
                  </a>
                  <%!-- Retry count --%>
                  <span
                    :if={subtask.retry_count && subtask.retry_count > 0}
                    class="badge badge-sm badge-warning badge-outline"
                  >
                    {subtask.retry_count} retries
                  </span>
                  <%!-- Expand indicator --%>
                  <.icon
                    name={
                      if @expanded_subtask_id == subtask.id,
                        do: "hero-chevron-up",
                        else: "hero-chevron-down"
                    }
                    class="size-4 opacity-50"
                  />
                </div>
              </div>

              <%!-- Expanded detail --%>
              <div
                :if={@expanded_subtask_id == subtask.id}
                class="px-4 pb-4 border-t border-base-300"
              >
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-3">
                  <%!-- Spec --%>
                  <div>
                    <h4 class="text-sm font-semibold mb-1">Specification</h4>
                    <p class="text-sm whitespace-pre-wrap bg-base-300 p-2 rounded max-h-40 overflow-y-auto">
                      {subtask.spec}
                    </p>
                  </div>

                  <%!-- Details --%>
                  <div class="space-y-3">
                    <%!-- Test results --%>
                    <div :if={subtask.test_passed != nil}>
                      <h4 class="text-sm font-semibold mb-1">Test Results</h4>
                      <span class={[
                        "badge badge-sm",
                        if(subtask.test_passed, do: "badge-success", else: "badge-error")
                      ]}>
                        {if subtask.test_passed, do: "Passed", else: "Failed"}
                      </span>
                      <details :if={subtask.test_output} class="mt-1">
                        <summary class="text-xs cursor-pointer opacity-70">Test output</summary>
                        <pre class="text-xs bg-base-300 p-2 rounded mt-1 max-h-32 overflow-y-auto whitespace-pre-wrap">{subtask.test_output}</pre>
                      </details>
                    </div>

                    <%!-- Review verdict --%>
                    <div :if={subtask.review_verdict}>
                      <h4 class="text-sm font-semibold mb-1">Review</h4>
                      <span class={[
                        "badge badge-sm",
                        cond do
                          subtask.review_verdict == "approved" -> "badge-success"
                          subtask.review_verdict == "rejected" -> "badge-error"
                          true -> "badge-warning"
                        end
                      ]}>
                        {subtask.review_verdict}
                      </span>
                      <p :if={subtask.review_reasoning} class="text-xs mt-1 opacity-70">
                        {subtask.review_reasoning}
                      </p>
                    </div>

                    <%!-- Error details --%>
                    <div :if={subtask.last_error}>
                      <h4 class="text-sm font-semibold mb-1 text-error">Last Error</h4>
                      <pre class="text-xs bg-error/10 p-2 rounded whitespace-pre-wrap max-h-32 overflow-y-auto">{subtask.last_error}</pre>
                    </div>

                    <%!-- Git info --%>
                    <div :if={subtask.branch_name}>
                      <h4 class="text-sm font-semibold mb-1">Branch</h4>
                      <code class="text-xs">{subtask.branch_name}</code>
                    </div>

                    <div :if={subtask.files_changed && subtask.files_changed != []}>
                      <h4 class="text-sm font-semibold mb-1">Files Changed</h4>
                      <ul class="text-xs list-disc list-inside">
                        <li :for={file <- subtask.files_changed}>{file}</li>
                      </ul>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Agent Output --%>
        <div :if={@agent_output != [] || agent_running?(@pipeline_state)} class="mt-4">
          <h3 class="text-base font-semibold mb-2">
            Agent Output
            <span
              :if={agent_running?(@pipeline_state)}
              class="loading loading-dots loading-xs ml-1"
            >
            </span>
          </h3>
          <div
            id="agent-output"
            phx-update="replace"
            class="bg-base-300 rounded-lg p-3 font-mono text-xs max-h-80 overflow-y-auto"
          >
            <div :for={{line, i} <- Enum.with_index(@agent_output)}>
              <span id={"line-#{i}"} class="whitespace-pre-wrap break-all">{line}</span>
            </div>
            <div :if={@agent_output == [] && agent_running?(@pipeline_state)} class="opacity-50">
              Waiting for agent output...
            </div>
          </div>
        </div>
      </div>

      <%!-- Queue Sidebar --%>
      <div class="w-64 flex-shrink-0 hidden lg:block">
        <div class="card bg-base-200 shadow-sm sticky top-4">
          <div class="card-body py-3">
            <h3 class="card-title text-sm">Task Queue</h3>
            <div :if={@queued_tasks == []} class="text-sm opacity-50 py-2">
              No tasks queued.
            </div>
            <ul class="space-y-2 mt-1">
              <li
                :for={qt <- @queued_tasks}
                class={[
                  "text-sm p-2 rounded",
                  if(@task && qt.id == @task.id,
                    do: "bg-primary/10 border border-primary/30",
                    else: "bg-base-300"
                  )
                ]}
              >
                <.link navigate={~p"/tasks/#{qt}"} class="link link-hover text-sm font-medium">
                  {qt.title}
                </.link>
                <div class="flex items-center gap-1 mt-1">
                  <span class={["badge badge-xs", task_status_badge_class(qt.status)]}>
                    {format_status(qt.status)}
                  </span>
                  <span :if={qt.queue_position} class="text-xs opacity-50">
                    #{qt.queue_position}
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp has_failed_task?(_queued_tasks, current_task) do
    has_failed =
      case Tasks.list_tasks_by_status("failed") do
        [_ | _] -> true
        _ -> false
      end

    has_failed or (current_task && current_task.status == "failed")
  rescue
    _ -> false
  end

  defp agent_running?(%{current_step: step}) when step in [:executing_subtask, :reviewing],
    do: true

  defp agent_running?(_), do: false
end
