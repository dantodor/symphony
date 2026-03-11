defmodule SymphonyV2Web.SettingsLive do
  use SymphonyV2Web, :live_view

  alias SymphonyV2.Agents.AgentRegistry
  alias SymphonyV2.AppConfig
  alias SymphonyV2.Settings
  alias SymphonyV2.Settings.CustomAgent

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get_settings()
    config = AppConfig.load()
    agents = AgentRegistry.all()
    custom_agents = Settings.list_custom_agents()

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:config, config)
      |> assign(:settings, settings)
      |> assign(:settings_form, to_form(Settings.change_settings(settings)))
      |> assign(:agents, agents)
      |> assign(:custom_agents, custom_agents)
      |> assign(:editing_settings, false)
      |> assign(:adding_agent, false)
      |> assign(:editing_agent_id, nil)
      |> assign(:agent_form, to_form(Settings.change_custom_agent(%CustomAgent{})))

    {:ok, socket}
  end

  @impl true
  def handle_event("edit_settings", _params, socket) do
    {:noreply, assign(socket, :editing_settings, true)}
  end

  def handle_event("cancel_edit_settings", _params, socket) do
    settings = socket.assigns.settings
    form = to_form(Settings.change_settings(settings))
    {:noreply, assign(socket, editing_settings: false, settings_form: form)}
  end

  def handle_event("validate_settings", %{"app_setting" => params}, socket) do
    changeset =
      socket.assigns.settings
      |> Settings.change_settings(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :settings_form, to_form(changeset))}
  end

  def handle_event("save_settings", %{"app_setting" => params}, socket) do
    case Settings.update_settings(params) do
      {:ok, settings} ->
        config = AppConfig.load()

        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:config, config)
         |> assign(:settings_form, to_form(Settings.change_settings(settings)))
         |> assign(:editing_settings, false)
         |> put_flash(:info, "Settings updated successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset))}
    end
  end

  def handle_event("add_agent", _params, socket) do
    form = to_form(Settings.change_custom_agent(%CustomAgent{}))
    {:noreply, assign(socket, adding_agent: true, editing_agent_id: nil, agent_form: form)}
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    agent = Settings.get_custom_agent!(id)
    form = to_form(Settings.change_custom_agent(agent))
    {:noreply, assign(socket, editing_agent_id: id, adding_agent: false, agent_form: form)}
  end

  def handle_event("cancel_agent", _params, socket) do
    {:noreply, assign(socket, adding_agent: false, editing_agent_id: nil)}
  end

  def handle_event("validate_agent", %{"custom_agent" => params}, socket) do
    params = parse_env_vars(params)

    agent =
      if socket.assigns.editing_agent_id do
        Settings.get_custom_agent!(socket.assigns.editing_agent_id)
      else
        %CustomAgent{}
      end

    changeset =
      agent
      |> Settings.change_custom_agent(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :agent_form, to_form(changeset))}
  end

  def handle_event("save_agent", %{"custom_agent" => params}, socket) do
    params = parse_env_vars(params)

    result =
      if socket.assigns.editing_agent_id do
        agent = Settings.get_custom_agent!(socket.assigns.editing_agent_id)
        Settings.update_custom_agent(agent, params)
      else
        Settings.create_custom_agent(params)
      end

    case result do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> assign(:custom_agents, Settings.list_custom_agents())
         |> assign(:agents, AgentRegistry.all())
         |> assign(:adding_agent, false)
         |> assign(:editing_agent_id, nil)
         |> put_flash(:info, "Agent saved successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :agent_form, to_form(changeset))}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    agent = Settings.get_custom_agent!(id)

    case Settings.delete_custom_agent(agent) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:custom_agents, Settings.list_custom_agents())
         |> assign(:agents, AgentRegistry.all())
         |> put_flash(:info, "Agent deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.header>
        Application Settings
        <:subtitle>View and manage Symphony v2 configuration.</:subtitle>
      </.header>

      <div class="mt-8 space-y-8">
        <%!-- Current Configuration --%>
        <section>
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">Configuration</h2>
            <%= if !@editing_settings do %>
              <button phx-click="edit_settings" class="btn btn-sm btn-primary">
                <.icon name="hero-pencil-square" class="size-4 mr-1" /> Edit
              </button>
            <% end %>
          </div>

          <%= if @editing_settings do %>
            <.form
              for={@settings_form}
              phx-change="validate_settings"
              phx-submit="save_settings"
              class="space-y-4"
            >
              <.input field={@settings_form[:test_command]} type="text" label="Test Command" />

              <.input
                field={@settings_form[:planning_agent]}
                type="select"
                label="Planning Agent"
                options={agent_options(@agents)}
              />

              <.input
                field={@settings_form[:review_agent]}
                type="select"
                label="Review Agent"
                options={agent_options(@agents)}
              />

              <.input
                field={@settings_form[:default_agent]}
                type="select"
                label="Default Agent"
                options={agent_options(@agents)}
              />

              <.input
                field={@settings_form[:agent_timeout_ms]}
                type="number"
                label="Agent Timeout (ms)"
              />

              <.input
                field={@settings_form[:max_retries]}
                type="number"
                label="Max Retries"
              />

              <.input
                field={@settings_form[:review_failure_action]}
                type="select"
                label="Review Failure Action"
                options={[
                  {"Auto-approve (skip failed review)", "auto_approve"},
                  {"Fail subtask", "fail"}
                ]}
              />

              <.input
                field={@settings_form[:dangerously_skip_permissions]}
                type="checkbox"
                label="Dangerously Skip Permissions (auto-approve all gates)"
              />

              <div class="flex gap-2">
                <button type="submit" class="btn btn-primary btn-sm">Save Settings</button>
                <button type="button" phx-click="cancel_edit_settings" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
              </div>
            </.form>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <tbody>
                  <tr>
                    <td class="font-medium w-1/3">Repo Path</td>
                    <td>
                      <code class="text-sm">{@config.repo_path || "not set"}</code>
                      <%= if @config.repo_path && File.dir?(@config.repo_path) do %>
                        <span class="badge badge-success badge-sm ml-2">valid</span>
                      <% else %>
                        <span class="badge badge-error badge-sm ml-2">invalid</span>
                      <% end %>
                    </td>
                  </tr>
                  <tr>
                    <td class="font-medium">Workspace Root</td>
                    <td>
                      <code class="text-sm">{@config.workspace_root || "not set"}</code>
                      <%= if @config.workspace_root && File.dir?(@config.workspace_root) do %>
                        <span class="badge badge-success badge-sm ml-2">valid</span>
                      <% else %>
                        <span class="badge badge-error badge-sm ml-2">invalid</span>
                      <% end %>
                    </td>
                  </tr>
                  <tr>
                    <td class="font-medium">Test Command</td>
                    <td><code class="text-sm">{@config.test_command}</code></td>
                  </tr>
                  <tr>
                    <td class="font-medium">Planning Agent</td>
                    <td>{@config.planning_agent}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Review Agent</td>
                    <td>{@config.review_agent}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Default Agent</td>
                    <td>{@config.default_agent}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Agent Timeout</td>
                    <td>{format_timeout(@config.agent_timeout_ms)}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Max Retries</td>
                    <td>{@config.max_retries}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Review Failure Action</td>
                    <td>{format_review_failure_action(@config.review_failure_action)}</td>
                  </tr>
                  <tr>
                    <td class="font-medium">Skip Permissions</td>
                    <td>
                      <%= if @config.dangerously_skip_permissions do %>
                        <span class="badge badge-warning badge-sm">enabled</span>
                      <% else %>
                        <span class="badge badge-ghost badge-sm">disabled</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%!-- Agent Registry --%>
        <section>
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">Agent Registry</h2>
            <button phx-click="add_agent" class="btn btn-sm btn-primary">
              <.icon name="hero-plus" class="size-4 mr-1" /> Add Agent
            </button>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-zebra" id="agents-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Command</th>
                  <th>Prompt Flag</th>
                  <th>Skip Permissions</th>
                  <th>Env Vars</th>
                  <th>Installed</th>
                  <th>Source</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={agent <- @agents} id={"agent-#{agent.name}"}>
                  <td class="font-mono text-sm">{agent.name}</td>
                  <td class="font-mono text-sm">{agent.command}</td>
                  <td class="font-mono text-sm">{agent.prompt_flag}</td>
                  <td class="font-mono text-sm">{agent.skip_permissions_flag || "—"}</td>
                  <td>
                    <span :for={var <- agent.env_vars} class="badge badge-outline badge-sm mr-1">
                      {var}
                    </span>
                    <span :if={agent.env_vars == []}>—</span>
                  </td>
                  <td>
                    <%= if Settings.command_installed?(agent.command) do %>
                      <span class="badge badge-success badge-sm">installed</span>
                    <% else %>
                      <span class="badge badge-error badge-sm">not found</span>
                    <% end %>
                  </td>
                  <td>
                    <%= if builtin?(agent, @custom_agents) do %>
                      <span class="badge badge-ghost badge-sm">built-in</span>
                    <% else %>
                      <span class="badge badge-info badge-sm">custom</span>
                    <% end %>
                  </td>
                  <td>
                    <%= if !builtin?(agent, @custom_agents) do %>
                      <% ca = find_custom_agent(agent, @custom_agents) %>
                      <%= if ca do %>
                        <div class="flex gap-1">
                          <button
                            phx-click="edit_agent"
                            phx-value-id={ca.id}
                            class="btn btn-ghost btn-xs"
                          >
                            <.icon name="hero-pencil-square" class="size-3" />
                          </button>
                          <button
                            phx-click="delete_agent"
                            phx-value-id={ca.id}
                            data-confirm="Delete this agent?"
                            class="btn btn-ghost btn-xs text-error"
                          >
                            <.icon name="hero-trash" class="size-3" />
                          </button>
                        </div>
                      <% end %>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Add/Edit Agent Form --%>
          <%= if @adding_agent || @editing_agent_id do %>
            <div class="card bg-base-200 mt-4">
              <div class="card-body">
                <h3 class="card-title text-base">
                  {if @editing_agent_id, do: "Edit Agent", else: "Add Custom Agent"}
                </h3>
                <.form
                  for={@agent_form}
                  phx-change="validate_agent"
                  phx-submit="save_agent"
                  class="space-y-3"
                >
                  <.input field={@agent_form[:name]} type="text" label="Name" placeholder="my_agent" />
                  <.input
                    field={@agent_form[:command]}
                    type="text"
                    label="CLI Command"
                    placeholder="my-agent-cli"
                  />
                  <.input
                    field={@agent_form[:prompt_flag]}
                    type="text"
                    label="Prompt Flag"
                    placeholder="-p"
                  />
                  <.input
                    field={@agent_form[:skip_permissions_flag]}
                    type="text"
                    label="Skip Permissions Flag (optional)"
                    placeholder="--no-confirm"
                  />
                  <.input
                    field={@agent_form[:env_vars]}
                    type="text"
                    label="Environment Variables (comma-separated)"
                    placeholder="MY_API_KEY,OTHER_KEY"
                    value={
                      Enum.join(Phoenix.HTML.Form.input_value(@agent_form, :env_vars) || [], ",")
                    }
                  />
                  <div class="flex gap-2">
                    <button type="submit" class="btn btn-primary btn-sm">
                      {if @editing_agent_id, do: "Update Agent", else: "Add Agent"}
                    </button>
                    <button type="button" phx-click="cancel_agent" class="btn btn-ghost btn-sm">
                      Cancel
                    </button>
                  </div>
                </.form>
              </div>
            </div>
          <% end %>
        </section>
      </div>
    </div>
    """
  end

  defp agent_options(agents) do
    Enum.map(agents, fn agent -> {Atom.to_string(agent.name), Atom.to_string(agent.name)} end)
  end

  defp format_timeout(ms) when is_integer(ms) do
    cond do
      ms >= 60_000 -> "#{div(ms, 60_000)} min"
      ms >= 1_000 -> "#{div(ms, 1_000)} sec"
      true -> "#{ms} ms"
    end
  end

  defp format_timeout(_), do: "unknown"

  defp format_review_failure_action(:auto_approve), do: "Auto-approve"
  defp format_review_failure_action(:fail), do: "Fail subtask"
  defp format_review_failure_action(_), do: "Auto-approve"

  defp builtin?(agent, custom_agents) do
    not Enum.any?(custom_agents, fn ca -> String.to_atom(ca.name) == agent.name end)
  end

  defp find_custom_agent(agent, custom_agents) do
    Enum.find(custom_agents, fn ca -> String.to_atom(ca.name) == agent.name end)
  end

  defp parse_env_vars(params) do
    case params["env_vars"] do
      val when is_binary(val) ->
        vars =
          val
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "env_vars", vars)

      _ ->
        params
    end
  end
end
