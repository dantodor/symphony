defmodule SymphonyV2Web.StackReviewLive do
  @moduledoc """
  PR stack review page for completed tasks awaiting final review.

  Shows all PRs in the stack, per-PR summaries, approve/merge and reject controls,
  and real-time merge progress display.
  """

  use SymphonyV2Web, :live_view

  alias SymphonyV2.Plans
  alias SymphonyV2.PubSub.Topics
  alias SymphonyV2.Tasks

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    task = Tasks.get_task!(task_id)
    plan = Plans.get_plan_by_task_id(task_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyV2.PubSub, Topics.task(task.id))
    end

    {:ok,
     socket
     |> assign(:page_title, "Stack Review — #{task.title}")
     |> assign(:task, task)
     |> assign(:plan, plan)
     |> assign(:merge_status, nil)
     |> assign(:reject_feedback, "")
     |> assign(:show_reject_form, false)}
  end

  # --- Event handlers ---

  @impl true
  def handle_event("approve_merge", _params, socket) do
    case SymphonyV2.Pipeline.approve_final() do
      :ok ->
        {:noreply,
         socket
         |> assign(:merge_status, :merging)
         |> put_flash(:info, "Merge started...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start merge: #{inspect(reason)}")}
    end
  end

  def handle_event("show_reject_form", _params, socket) do
    {:noreply, assign(socket, :show_reject_form, true)}
  end

  def handle_event("cancel_reject", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reject_form, false)
     |> assign(:reject_feedback, "")}
  end

  def handle_event("update_feedback", %{"feedback" => feedback}, socket) do
    {:noreply, assign(socket, :reject_feedback, feedback)}
  end

  def handle_event("reject_final", %{"feedback" => feedback}, socket) do
    feedback = String.trim(feedback)

    if feedback == "" do
      {:noreply, put_flash(socket, :error, "Please provide feedback for the rejection.")}
    else
      case SymphonyV2.Pipeline.reject_final(feedback) do
        :ok ->
          {:noreply,
           socket
           |> reload_task()
           |> assign(:show_reject_form, false)
           |> assign(:reject_feedback, "")
           |> put_flash(:info, "Task rejected with feedback.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not reject: #{inspect(reason)}")}
      end
    end
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:task_step, :merging}, socket) do
    {:noreply,
     socket
     |> reload_task()
     |> assign(:merge_status, :merging)}
  end

  def handle_info({:task_completed, _task_id}, socket) do
    {:noreply,
     socket
     |> reload_task()
     |> assign(:merge_status, :completed)
     |> put_flash(:info, "All PRs merged successfully!")}
  end

  def handle_info({:task_failed, reason}, socket) do
    {:noreply,
     socket
     |> reload_task()
     |> assign(:merge_status, {:failed, reason})
     |> put_flash(:error, "Merge failed: #{inspect(reason)}")}
  end

  def handle_info({:task_step, _step}, socket) do
    {:noreply, reload_task(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  defp reload_task(socket) do
    task = Tasks.get_task!(socket.assigns.task.id)
    plan = Plans.get_plan_by_task_id(task.id)

    socket
    |> assign(:task, task)
    |> assign(:plan, plan)
  end

  defp sorted_subtasks(nil), do: []
  defp sorted_subtasks(plan), do: plan.subtasks |> Enum.sort_by(& &1.position)

  defp subtasks_with_prs(plan) do
    sorted_subtasks(plan)
    |> Enum.filter(&(&1.pr_url != nil))
  end

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

  defp review_badge_class(verdict) do
    case verdict do
      "approved" -> "badge-success"
      "rejected" -> "badge-error"
      "skipped" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp base_branch_for(subtask, plan) do
    if subtask.position == 1 do
      "main"
    else
      prev =
        sorted_subtasks(plan)
        |> Enum.find(&(&1.position == subtask.position - 1))

      case prev do
        nil -> "main"
        %{branch_name: nil} -> "main"
        %{branch_name: name} -> name
      end
    end
  end

  defp files_count(subtask) do
    case subtask.files_changed do
      nil -> 0
      files -> length(files)
    end
  end

  defp awaiting_final_review?(task) do
    task.status == "executing"
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Stack Review
      <:subtitle>
        <.link navigate={~p"/tasks/#{@task}"} class="link link-hover">
          {@task.title}
        </.link>
        <span class={["badge badge-sm ml-2", status_badge_class(@task.status)]}>
          {format_status(@task.status)}
        </span>
      </:subtitle>
      <:actions>
        <.button navigate={~p"/tasks/#{@task}"}>
          Back to Task
        </.button>
      </:actions>
    </.header>

    <%!-- Merge Status Banner --%>
    <div :if={@merge_status == :merging} class="alert alert-info mt-4">
      <span class="loading loading-spinner loading-sm"></span>
      <span>Rebasing and merging PRs... This may take a moment.</span>
    </div>

    <div :if={@merge_status == :completed} class="alert alert-success mt-4">
      <.icon name="hero-check-circle" class="size-5" />
      <span>All PRs have been successfully merged!</span>
    </div>

    <div :if={match?({:failed, _}, @merge_status)} class="alert alert-error mt-4">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <div>
        <p class="font-semibold">Merge failed</p>
        <p class="text-sm">{elem(@merge_status, 1)}</p>
      </div>
    </div>

    <%!-- PR Stack List --%>
    <div class="mt-6">
      <h2 class="text-lg font-semibold mb-3">
        Pull Requests
        <span class="badge badge-sm badge-outline ml-1">
          {length(subtasks_with_prs(@plan))}
        </span>
      </h2>

      <div :if={subtasks_with_prs(@plan) == []} class="card bg-base-200">
        <div class="card-body py-6 text-center opacity-60">
          No PRs have been created yet.
        </div>
      </div>

      <div class="space-y-3">
        <div
          :for={subtask <- subtasks_with_prs(@plan)}
          class="card bg-base-200 shadow-sm"
        >
          <div class="card-body py-4">
            <%!-- PR Header --%>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="badge badge-sm badge-primary font-mono">
                  #{subtask.pr_number}
                </span>
                <span class="font-medium">{subtask.title}</span>
              </div>
              <a
                href={subtask.pr_url}
                target="_blank"
                class="btn btn-sm btn-outline btn-primary"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" /> View on GitHub
              </a>
            </div>

            <%!-- PR Details --%>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mt-3 text-sm">
              <div>
                <span class="opacity-50">Base</span>
                <div class="font-mono text-xs truncate" title={base_branch_for(subtask, @plan)}>
                  {base_branch_for(subtask, @plan)}
                </div>
              </div>
              <div>
                <span class="opacity-50">Branch</span>
                <div class="font-mono text-xs truncate" title={subtask.branch_name}>
                  {subtask.branch_name}
                </div>
              </div>
              <div>
                <span class="opacity-50">Files Changed</span>
                <div>{files_count(subtask)} files</div>
              </div>
              <div>
                <span class="opacity-50">Agent</span>
                <div>
                  <span class="badge badge-xs badge-outline">{subtask.agent_type}</span>
                </div>
              </div>
            </div>

            <%!-- Files Changed --%>
            <details
              :if={subtask.files_changed && subtask.files_changed != []}
              class="mt-2"
            >
              <summary class="text-xs cursor-pointer opacity-70">
                Show changed files
              </summary>
              <ul class="text-xs list-disc list-inside mt-1 bg-base-300 p-2 rounded">
                <li :for={file <- subtask.files_changed}>{file}</li>
              </ul>
            </details>

            <%!-- Review Summary --%>
            <div :if={subtask.review_verdict} class="mt-3 border-t border-base-300 pt-3">
              <div class="flex items-center gap-2">
                <span class="text-sm opacity-50">Review:</span>
                <span class={["badge badge-sm", review_badge_class(subtask.review_verdict)]}>
                  {subtask.review_verdict}
                </span>
              </div>
              <p :if={subtask.review_reasoning} class="text-sm opacity-70 mt-1">
                {subtask.review_reasoning}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- All subtasks overview (including those without PRs) --%>
    <div :if={@plan && sorted_subtasks(@plan) != subtasks_with_prs(@plan)} class="mt-6">
      <h2 class="text-lg font-semibold mb-3">All Subtasks</h2>
      <div class="overflow-x-auto">
        <table class="table table-zebra table-sm w-full">
          <thead>
            <tr>
              <th>#</th>
              <th>Title</th>
              <th>Status</th>
              <th>PR</th>
              <th>Review</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={subtask <- sorted_subtasks(@plan)}>
              <td>{subtask.position}</td>
              <td>{subtask.title}</td>
              <td>
                <span class={[
                  "badge badge-sm",
                  subtask.status == "succeeded" && "badge-success",
                  subtask.status == "failed" && "badge-error",
                  subtask.status not in ["succeeded", "failed"] && "badge-ghost"
                ]}>
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
                <span :if={!subtask.pr_url} class="opacity-30">—</span>
              </td>
              <td>
                <span
                  :if={subtask.review_verdict}
                  class={["badge badge-sm", review_badge_class(subtask.review_verdict)]}
                >
                  {subtask.review_verdict}
                </span>
                <span :if={!subtask.review_verdict} class="opacity-30">—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <%!-- Action Buttons --%>
    <div :if={awaiting_final_review?(@task) && @merge_status != :merging} class="mt-6">
      <div class="card bg-base-200 shadow-sm">
        <div class="card-body">
          <h3 class="card-title text-base">Final Review</h3>
          <p class="text-sm opacity-70">
            All subtasks have completed. Review the PR stack above and approve to merge,
            or reject with feedback.
          </p>

          <div :if={!@show_reject_form} class="flex gap-3 mt-3">
            <button phx-click="approve_merge" class="btn btn-success">
              <.icon name="hero-check" class="size-4" /> Approve &amp; Merge
            </button>
            <button phx-click="show_reject_form" class="btn btn-error btn-outline">
              <.icon name="hero-x-mark" class="size-4" /> Reject
            </button>
          </div>

          <div :if={@show_reject_form} class="mt-3">
            <form phx-submit="reject_final">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Rejection feedback</span>
                </label>
                <textarea
                  name="feedback"
                  class="textarea textarea-bordered h-24"
                  placeholder="Explain why the PR stack is being rejected..."
                  phx-change="update_feedback"
                  value={@reject_feedback}
                >{@reject_feedback}</textarea>
              </div>
              <div class="flex gap-3 mt-3">
                <button type="submit" class="btn btn-error">
                  <.icon name="hero-x-mark" class="size-4" /> Reject with Feedback
                </button>
                <button type="button" phx-click="cancel_reject" class="btn btn-ghost">
                  Cancel
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>

    <%!-- Completed / Failed state --%>
    <div :if={@task.status == "completed" && @merge_status != :completed} class="mt-6">
      <div class="alert alert-success">
        <.icon name="hero-check-circle" class="size-5" />
        <span>This task has been completed and all PRs have been merged.</span>
      </div>
    </div>

    <div :if={@task.status == "failed"} class="mt-6">
      <div class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>This task has failed. Check the task detail page for error information.</span>
      </div>
    </div>

    <div class="mt-6">
      <.button navigate={~p"/tasks/#{@task}"}>Back to Task</.button>
    </div>
    """
  end
end
