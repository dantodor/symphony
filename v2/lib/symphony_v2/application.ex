defmodule SymphonyV2.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SymphonyV2Web.Telemetry,
      SymphonyV2.Repo,
      {DNSCluster, query: Application.get_env(:symphony_v2, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SymphonyV2.PubSub},
      # Start a worker by calling: SymphonyV2.Worker.start_link(arg)
      # {SymphonyV2.Worker, arg},
      # Start to serve requests, typically the last entry
      SymphonyV2Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SymphonyV2.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SymphonyV2Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
