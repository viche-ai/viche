defmodule VicheWeb.LiveHelpers do
  @moduledoc "Shared helpers for LiveView modules."

  @doc "Formats a DateTime as a human-readable relative time string."
  @spec format_last_seen(DateTime.t() | nil) :: String.t()
  def format_last_seen(nil), do: "never"

  def format_last_seen(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 10 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  @doc "Formats an uptime duration from a registered_at DateTime."
  @spec format_uptime(DateTime.t() | nil) :: String.t()
  def format_uptime(nil), do: "unknown"

  def format_uptime(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 ->
        "#{diff}s"

      diff < 3600 ->
        "#{div(diff, 60)}m"

      diff < 86400 ->
        h = div(diff, 3600)
        m = div(rem(diff, 3600), 60)
        "#{h}h #{m}m"

      true ->
        d = div(diff, 86400)
        h = div(rem(diff, 86400), 3600)
        "#{d}d #{h}h"
    end
  end
end
