defmodule SymphonyV2.Agents.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for AgentProcess instances.

  Uses `:temporary` restart strategy — failed agents are not automatically
  restarted. The Pipeline GenServer handles retry logic instead.
  """
  use DynamicSupervisor

  alias SymphonyV2.Agents.AgentProcess

  @doc "Starts the AgentSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Starts an AgentProcess under this supervisor."
  @spec start_agent(AgentProcess.start_opts()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) do
    start_agent(__MODULE__, opts)
  end

  @doc "Starts an AgentProcess under the given supervisor."
  @spec start_agent(GenServer.server(), AgentProcess.start_opts()) ::
          DynamicSupervisor.on_start_child()
  def start_agent(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {AgentProcess, opts})
  end

  @doc "Returns the count of currently running agent processes."
  @spec running_count() :: non_neg_integer()
  def running_count do
    running_count(__MODULE__)
  end

  @doc "Returns the count of currently running agent processes under the given supervisor."
  @spec running_count(GenServer.server()) :: non_neg_integer()
  def running_count(supervisor) do
    %{active: active} = DynamicSupervisor.count_children(supervisor)
    active
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
