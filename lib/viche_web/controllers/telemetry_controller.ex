defmodule VicheWeb.TelemetryController do
  @moduledoc """
  Receives telemetry reports from self-hosted Viche instances.

  This endpoint runs on the hosted viche.ai instance and stores incoming
  reports in the `telemetry_reports` table with a JSONB payload column.
  """

  use VicheWeb, :controller

  alias Viche.Repo
  alias Viche.Telemetry.Report

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    attrs = %{
      instance_id: params["instance_id"],
      payload: params["payload"] || %{},
      reported_at: parse_reported_at(params["reported_at"])
    }

    changeset = Report.changeset(%Report{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _report} ->
        conn
        |> put_status(:created)
        |> json(%{status: "ok"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_report",
          details: format_errors(changeset)
        })
    end
  end

  defp parse_reported_at(nil), do: DateTime.utc_now()

  defp parse_reported_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_reported_at(_), do: DateTime.utc_now()

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
