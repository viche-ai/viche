defmodule Viche.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VicheWeb.Telemetry,
      Viche.Repo,
      {DNSCluster, query: Application.get_env(:viche, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Viche.PubSub},
      {Registry, keys: :unique, name: Viche.AgentRegistry},
      {DynamicSupervisor, name: Viche.AgentSupervisor, strategy: :one_for_one},
      Viche.MessageCounter,
      Viche.Telemetry.Reporter,
      # Start to serve requests, typically the last entry
      VicheWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Viche.Supervisor]
    Viche.JoinTokens.init()
    Viche.SettingsStore.init()
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VicheWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
