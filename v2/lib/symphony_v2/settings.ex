defmodule SymphonyV2.Settings do
  @moduledoc """
  Context for managing application settings and custom agent configurations.

  Settings are stored as a singleton row in the `app_settings` table.
  Custom agents are stored in the `custom_agents` table.
  """

  alias SymphonyV2.Repo
  alias SymphonyV2.Settings.AppSetting
  alias SymphonyV2.Settings.CustomAgent

  # --- App Settings ---

  @doc "Returns the current app settings, creating defaults if none exist."
  @spec get_settings() :: %AppSetting{}
  def get_settings do
    case Repo.one(AppSetting) do
      nil ->
        {:ok, setting} = Repo.insert(%AppSetting{})
        setting

      setting ->
        setting
    end
  end

  @doc "Updates the app settings with the given attributes."
  @spec update_settings(map()) :: {:ok, %AppSetting{}} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs) do
    get_settings()
    |> AppSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc "Returns a changeset for the current settings (for form rendering)."
  @spec change_settings(%AppSetting{}, map()) :: Ecto.Changeset.t()
  def change_settings(%AppSetting{} = setting, attrs \\ %{}) do
    AppSetting.changeset(setting, attrs)
  end

  # --- Custom Agents ---

  @doc "Lists all custom agents."
  @spec list_custom_agents() :: [%CustomAgent{}]
  def list_custom_agents do
    Repo.all(CustomAgent)
  end

  @doc "Gets a custom agent by ID."
  @spec get_custom_agent!(String.t()) :: %CustomAgent{}
  def get_custom_agent!(id), do: Repo.get!(CustomAgent, id)

  @doc "Creates a new custom agent."
  @spec create_custom_agent(map()) :: {:ok, %CustomAgent{}} | {:error, Ecto.Changeset.t()}
  def create_custom_agent(attrs) do
    %CustomAgent{}
    |> CustomAgent.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a custom agent."
  @spec update_custom_agent(%CustomAgent{}, map()) ::
          {:ok, %CustomAgent{}} | {:error, Ecto.Changeset.t()}
  def update_custom_agent(%CustomAgent{} = agent, attrs) do
    agent
    |> CustomAgent.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a custom agent."
  @spec delete_custom_agent(%CustomAgent{}) ::
          {:ok, %CustomAgent{}} | {:error, Ecto.Changeset.t()}
  def delete_custom_agent(%CustomAgent{} = agent) do
    Repo.delete(agent)
  end

  @doc "Returns a changeset for a custom agent (for form rendering)."
  @spec change_custom_agent(%CustomAgent{}, map()) :: Ecto.Changeset.t()
  def change_custom_agent(%CustomAgent{} = agent, attrs \\ %{}) do
    CustomAgent.changeset(agent, attrs)
  end

  # --- Pipeline Paused State ---

  @doc "Returns whether the pipeline is currently paused (persisted across restarts)."
  @spec get_pipeline_paused() :: boolean()
  def get_pipeline_paused do
    get_settings().pipeline_paused
  rescue
    _ -> false
  end

  @doc "Persists the pipeline paused state."
  @spec set_pipeline_paused(boolean()) :: :ok
  def set_pipeline_paused(paused) when is_boolean(paused) do
    setting = get_settings()

    setting
    |> Ecto.Changeset.change(%{pipeline_paused: paused})
    |> Repo.update()

    :ok
  end

  @doc """
  Checks whether a CLI command is installed on the system.
  Returns true if `System.find_executable/1` finds it.
  """
  @spec command_installed?(String.t()) :: boolean()
  def command_installed?(command) do
    System.find_executable(command) != nil
  end
end
