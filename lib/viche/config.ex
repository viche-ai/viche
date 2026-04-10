defmodule Viche.Config do
  @moduledoc """
  Runtime configuration helpers for Viche.

  All functions read application config at runtime (not compile time),
  making them safe to use in releases where config is set via environment variables.
  """

  @doc """
  Returns the configured application URL (e.g. `"https://viche.ai"` or `"http://localhost:4000"`).
  """
  @spec app_url() :: String.t()
  def app_url do
    Application.get_env(:viche, :app_url, "http://localhost:4000")
  end

  @doc """
  Extracts the host from the configured app URL (e.g. `"viche.ai"` or `"localhost"`).
  """
  @spec host() :: String.t()
  def host do
    URI.parse(app_url()).host || "localhost"
  end

  @doc """
  Returns the WebSocket URL derived from the app URL.

  Converts `https://` to `wss://` and `http://` to `ws://`, then appends `/socket`.
  """
  @spec ws_url() :: String.t()
  def ws_url do
    app_url()
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/socket")
  end

  @doc """
  Returns the well-known agent-registry URL for this instance.
  """
  @spec well_known_url() :: String.t()
  def well_known_url do
    "#{app_url()}/.well-known/agent-registry"
  end

  @doc """
  Returns the configured email sender as a `{name, address}` tuple.
  """
  @spec email_from() :: {String.t(), String.t()}
  def email_from do
    Application.get_env(:viche, :email_from, {"Viche", "noreply@#{host()}"})
  end

  @doc """
  Returns `true` if this instance is the hosted viche.ai production service.
  """
  @spec hosted?() :: boolean()
  def hosted? do
    host() == "viche.ai"
  end
end
