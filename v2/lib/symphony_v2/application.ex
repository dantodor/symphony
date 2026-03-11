defmodule SymphonyV2.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      SymphonyV2Web.Telemetry,
      SymphonyV2.Repo,
      {DNSCluster, query: Application.get_env(:symphony_v2, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SymphonyV2.PubSub},
      SymphonyV2.Agents.AgentSupervisor,
      SymphonyV2.Pipeline,
      # Start to serve requests, typically the last entry
      SymphonyV2Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SymphonyV2.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Validate config after repo is started
    case SymphonyV2.AppConfig.load_and_validate() do
      {:ok, _config} ->
        :ok

      {:error, errors} ->
        Logger.warning("AppConfig validation warnings at startup: #{inspect(errors)}")
    end

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SymphonyV2Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
