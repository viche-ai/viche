defmodule Viche.SettingsStore do
  @moduledoc """
  Simple ETS-backed store for Mission Control UI settings.
  Persists for the lifetime of the Elixir node.
  """
  @table :mission_control_settings

  @defaults %{
    registry_url: "https://viche.fly.dev",
    namespace: "global",
    agent_prefix: "my-agent",
    require_auth: false,
    live_feed: true,
    animate_graph: true
  }

  def init do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, {:settings, @defaults})
  end

  @spec get() :: map()
  def get do
    case :ets.lookup(@table, :settings) do
      [{:settings, settings}] -> settings
      [] -> @defaults
    end
  end

  @spec put(map()) :: :ok
  def put(settings) do
    :ets.insert(@table, {:settings, settings})
    :ok
  end

  @spec defaults() :: map()
  def defaults, do: @defaults
end
