defmodule Viche.Telemetry.Reporter do
  @moduledoc """
  GenServer that periodically collects anonymized usage stats and sends them
  to the hosted Viche instance at viche.ai.

  ## Opt-out

  Set `VICHE_TELEMETRY=false` to disable telemetry reporting entirely.
  The reporter process will still start but will not send any data.

  ## What is reported

  Only aggregate, non-identifying data is sent:

  - Viche version, Elixir/OTP version, OS type
  - Active agent count, message count, registry count, user count
  - Instance uptime

  No PII, agent names, message content, or user emails are ever included.
  """

  use GenServer

  require Logger

  alias Viche.Telemetry.Collector
  alias Viche.Telemetry.InstanceId

  @report_interval_ms :timer.hours(6)
  @endpoint "https://viche.ai/api/telemetry/reports"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Wait a bit after boot before the first report so the app is fully warmed up.
    schedule_report(:timer.minutes(5))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:report, state) do
    send_report()
    schedule_report(@report_interval_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp schedule_report(delay) do
    Process.send_after(self(), :report, delay)
  end

  defp send_report do
    if should_report?() do
      do_send_report()
    else
      Logger.debug("Telemetry reporting disabled or running on hosted instance, skipping")
    end
  end

  defp should_report? do
    telemetry_enabled?() and not Viche.Config.hosted?()
  end

  defp telemetry_enabled? do
    Application.get_env(:viche, :telemetry_enabled, true)
  end

  defp do_send_report do
    instance_id = InstanceId.get_or_create()
    stats = Collector.collect()

    body =
      Jason.encode!(%{
        instance_id: instance_id,
        payload: stats,
        reported_at: DateTime.utc_now()
      })

    case Req.post(@endpoint, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Logger.debug("Telemetry report sent successfully")

      {:ok, %Req.Response{status: status}} ->
        Logger.debug("Telemetry report rejected (HTTP #{status})")

      {:error, reason} ->
        Logger.debug("Telemetry report failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.debug("Telemetry report error: #{inspect(error)}")
  end
end
