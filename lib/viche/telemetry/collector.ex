defmodule Viche.Telemetry.Collector do
  @moduledoc """
  Gathers anonymized usage statistics from the current Viche instance.

  All data is aggregate counts and system metadata — no PII, agent names,
  message content, or user emails are ever included.
  """

  alias Viche.Accounts.User
  alias Viche.Repo

  import Ecto.Query

  @doc """
  Collects a snapshot of current instance usage stats.
  """
  @spec collect() :: map()
  def collect do
    %{
      version: app_version(),
      elixir_version: System.version(),
      otp_release: otp_release(),
      os: os_info(),
      active_agents: active_agent_count(),
      messages_today: Viche.MessageCounter.get(),
      registries: live_registry_count(),
      user_count: user_count(),
      uptime_seconds: uptime_seconds()
    }
  end

  defp app_version do
    Application.spec(:viche, :vsn) |> to_string()
  end

  defp otp_release do
    :erlang.system_info(:otp_release) |> to_string()
  end

  defp os_info do
    {family, name} = :os.type()
    "#{family}:#{name}"
  end

  defp active_agent_count do
    Viche.AgentRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> length()
  end

  defp live_registry_count do
    Viche.Agents.list_registries() |> length()
  end

  defp user_count do
    Repo.one(from(u in User, select: count(u.id))) || 0
  end

  defp uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end
end
