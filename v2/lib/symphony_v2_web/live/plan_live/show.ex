defmodule SymphonyV2Web.PlanLive.Show do
  use SymphonyV2Web, :live_view

  alias SymphonyV2.Agents.AgentRegistry
  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    task = Tasks.get_task!(task_id)
    plan = Plans.get_plan_by_task_id(task.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))
    end

    {:ok,
     socket
     |> assign(:page_title, "Plan: #{task.title}")
     |> assign(:task, task)
     |> assign(:plan, plan)
     |> assign(:agent_types, AgentRegistry.agent_type_strings())
     |> assign(:editing_subtask_id, nil)
     |> assign(:adding_subtask, false)
     |> assign(:add_position, nil)
     |> assign_edit_form(nil)
     |> assign_add_form()}
  end

  @impl true
  def handle_event("approve_plan", _params, socket) do
    case SymphonyV2.Pipeline.approve_plan() do
      :ok ->
        {:noreply,
         socket
         |> reload_task()
         |> put_flash(:info, "Plan approved. Execution started.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not approve plan: #{inspect(reason)}")}
    end
  end

  def handle_event("reject_plan", _params, socket) do
    case SymphonyV2.Pipeline.reject_plan() do
      :ok ->
        {:noreply,
         socket
         |> reload_task()
         |> put_flash(:info, "Plan rejected. Re-planning...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not reject plan: #{inspect(reason)}")}
    end
  end

  def handle_event("edit_subtask", %{"id" => id}, socket) do
    subtask = Plans.get_subtask!(id)

    {:noreply,
     socket
     |> assign(:editing_subtask_id, id)
     |> assign_edit_form(subtask)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_subtask_id, nil)
     |> assign_edit_form(nil)}
  end

  def handle_event("validate_edit", %{"subtask" => params}, socket) do
    subtask = Plans.get_subtask!(socket.assigns.editing_subtask_id)

    changeset =
      subtask
      |> Plans.Subtask.edit_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset))}
  end

  def handle_event("save_edit", %{"subtask" => params}, socket) do
    subtask = Plans.get_subtask!(socket.assigns.editing_subtask_id)

    case Plans.update_subtask_plan_fields(subtask, params) do
      {:ok, _subtask} ->
        {:noreply,
         socket
         |> assign(:editing_subtask_id, nil)
         |> assign_edit_form(nil)
         |> reload_plan()
         |> put_flash(:info, "Subtask updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("move_up", %{"id" => id}, socket) do
    subtask = Plans.get_subtask!(id)

    case Plans.move_subtask_up(subtask) do
      :ok -> {:noreply, reload_plan(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("move_down", %{"id" => id}, socket) do
    subtask = Plans.get_subtask!(id)

    case Plans.move_subtask_down(subtask) do
      :ok -> {:noreply, reload_plan(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("show_add_form", %{"position" => position}, socket) do
    {pos, _} = Integer.parse(position)

    {:noreply,
     socket
     |> assign(:adding_subtask, true)
     |> assign(:add_position, pos)
     |> assign_add_form()}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_subtask, false)
     |> assign(:add_position, nil)
     |> assign_add_form()}
  end

  def handle_event("validate_add", %{"subtask" => params}, socket) do
    changeset =
      %Plans.Subtask{}
      |> Plans.Subtask.edit_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :add_form, to_form(changeset))}
  end

  def handle_event("save_add", %{"subtask" => params}, socket) do
    plan = socket.assigns.plan
    position = socket.assigns.add_position

    attrs =
      params
      |> Map.put("position", position)

    case Plans.add_subtask_to_plan(plan, attrs) do
      {:ok, _subtask} ->
        {:noreply,
         socket
         |> assign(:adding_subtask, false)
         |> assign(:add_position, nil)
         |> assign_add_form()
         |> reload_plan()
         |> put_flash(:info, "Subtask added.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not add subtask.")}
    end
  end

  def handle_event("delete_subtask", %{"id" => id}, socket) do
    subtask = Plans.get_subtask!(id)

    case Plans.delete_subtask(subtask) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload_plan()
         |> put_flash(:info, "Subtask removed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove subtask.")}
    end
  end

  # PubSub handlers
  @impl true
  def handle_info({:task_step, _step}, socket), do: {:noreply, reload_task(socket)}
  def handle_info({:task_completed, _id}, socket), do: {:noreply, reload_task(socket)}
  def handle_info({:task_failed, _reason}, socket), do: {:noreply, reload_task(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload_task(socket) do
    task = Tasks.get_task!(socket.assigns.task.id)
    plan = Plans.get_plan_by_task_id(task.id)

    socket
    |> assign(:task, task)
    |> assign(:plan, plan)
  end

  defp reload_plan(socket) do
    plan = Plans.get_plan_by_task_id(socket.assigns.task.id)
    assign(socket, :plan, plan)
  end

  defp assign_edit_form(socket, nil) do
    assign(socket, :edit_form, nil)
  end

  defp assign_edit_form(socket, subtask) do
    changeset = Plans.Subtask.edit_changeset(subtask, %{})
    assign(socket, :edit_form, to_form(changeset))
  end

  defp assign_add_form(socket) do
    changeset =
      Plans.Subtask.edit_changeset(%Plans.Subtask{}, %{
        "title" => "",
        "spec" => "",
        "agent_type" => "claude_code"
      })

    assign(socket, :add_form, to_form(changeset))
  end

  defp plan_editable?(task) do
    task.status == "plan_review"
  end

  defp sorted_subtasks(nil), do: []

  defp sorted_subtasks(plan) do
    plan.subtasks |> Enum.sort_by(& &1.position)
  end

  defp subtask_count(nil), do: 0
  defp subtask_count(plan), do: length(plan.subtasks)

  defp format_status(status) do
    status
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
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

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Execution Plan
      <:subtitle>
        <.link navigate={~p"/tasks/#{@task}"} class="link link-primary">{@task.title}</.link>
        <span class={["badge ml-2", status_badge_class(@task.status)]}>
          {format_status(@task.status)}
        </span>
      </:subtitle>
      <:actions>
        <.button :if={plan_editable?(@task)} phx-click="approve_plan" variant="primary">
          Approve Plan
        </.button>
        <.button :if={plan_editable?(@task)} phx-click="reject_plan">
          Reject &amp; Re-plan
        </.button>
      </:actions>
    </.header>

    <div :if={@plan == nil} class="mt-6">
      <div class="alert">
        <span>No execution plan has been generated yet.</span>
      </div>
    </div>

    <div :if={@plan} class="mt-6">
      <%!-- Subtask List --%>
      <div class="space-y-3">
        <div :for={subtask <- sorted_subtasks(@plan)} class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <%!-- View Mode --%>
            <div :if={@editing_subtask_id != subtask.id}>
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <div class="flex items-center gap-2">
                    <span class="badge badge-sm badge-neutral">{subtask.position}</span>
                    <h3 class="font-semibold">{subtask.title}</h3>
                    <span class="badge badge-sm badge-outline">{subtask.agent_type}</span>
                    <span class={["badge badge-sm", subtask_status_class(subtask.status)]}>
                      {format_status(subtask.status)}
                    </span>
                  </div>
                  <p class="mt-2 text-sm whitespace-pre-wrap opacity-70">{subtask.spec}</p>
                </div>

                <div :if={plan_editable?(@task)} class="flex items-center gap-1 ml-4 shrink-0">
                  <button
                    :if={subtask.position > 1}
                    phx-click="move_up"
                    phx-value-id={subtask.id}
                    class="btn btn-xs btn-ghost"
                    title="Move up"
                  >
                    <.icon name="hero-arrow-up" class="size-4" />
                  </button>
                  <button
                    :if={subtask.position < subtask_count(@plan)}
                    phx-click="move_down"
                    phx-value-id={subtask.id}
                    class="btn btn-xs btn-ghost"
                    title="Move down"
                  >
                    <.icon name="hero-arrow-down" class="size-4" />
                  </button>
                  <button
                    phx-click="edit_subtask"
                    phx-value-id={subtask.id}
                    class="btn btn-xs btn-ghost"
                    title="Edit"
                  >
                    <.icon name="hero-pencil" class="size-4" />
                  </button>
                  <button
                    phx-click="delete_subtask"
                    phx-value-id={subtask.id}
                    data-confirm="Are you sure you want to remove this subtask?"
                    class="btn btn-xs btn-ghost text-error"
                    title="Remove"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>
            </div>

            <%!-- Edit Mode --%>
            <div :if={@editing_subtask_id == subtask.id}>
              <.form
                for={@edit_form}
                phx-change="validate_edit"
                phx-submit="save_edit"
                class="space-y-3"
              >
                <.input field={@edit_form[:title]} label="Title" />
                <.input field={@edit_form[:spec]} type="textarea" label="Spec" rows="6" />
                <.input
                  field={@edit_form[:agent_type]}
                  type="select"
                  label="Agent Type"
                  options={@agent_types}
                />
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">Save</.button>
                  <.button type="button" phx-click="cancel_edit">Cancel</.button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>

      <%!-- Add Subtask --%>
      <div :if={plan_editable?(@task)} class="mt-4">
        <div :if={!@adding_subtask}>
          <button
            phx-click="show_add_form"
            phx-value-position={subtask_count(@plan) + 1}
            class="btn btn-sm btn-outline btn-primary"
          >
            <.icon name="hero-plus" class="size-4" /> Add Subtask
          </button>
        </div>

        <div :if={@adding_subtask} class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <h3 class="font-semibold mb-2">
              Add Subtask at Position {@add_position}
            </h3>
            <.form
              for={@add_form}
              phx-change="validate_add"
              phx-submit="save_add"
              class="space-y-3"
            >
              <.input field={@add_form[:title]} label="Title" />
              <.input field={@add_form[:spec]} type="textarea" label="Spec" rows="4" />
              <.input
                field={@add_form[:agent_type]}
                type="select"
                label="Agent Type"
                options={@agent_types}
              />
              <div class="flex gap-2">
                <.button type="submit" variant="primary">Add</.button>
                <.button type="button" phx-click="cancel_add">Cancel</.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>

    <div class="mt-6">
      <.button navigate={~p"/tasks/#{@task}"}>Back to Task</.button>
    </div>
    """
  end
end
