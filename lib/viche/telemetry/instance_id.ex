defmodule Viche.Telemetry.InstanceId do
  @moduledoc """
  Manages a persistent, anonymous UUID that identifies this Viche instance.

  The ID is generated once on first boot and stored in the `instance_info`
  database table. It contains no PII — just a random UUID used to correlate
  telemetry reports from the same deployment.
  """

  import Ecto.Query

  alias Viche.Repo

  @doc """
  Returns the instance UUID, creating one if it doesn't exist yet.
  """
  @spec get_or_create() :: String.t()
  def get_or_create do
    case get() do
      nil -> create()
      id -> id
    end
  end

  @spec get() :: String.t() | nil
  defp get do
    query = from(i in "instance_info", select: i.instance_id, limit: 1)

    case Repo.one(query) do
      nil -> nil
      uuid -> Ecto.UUID.cast!(uuid)
    end
  end

  @spec create() :: String.t()
  defp create do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("instance_info", [%{instance_id: id, inserted_at: now}],
      on_conflict: :nothing
    )

    # Another process may have raced us; read back whatever is stored.
    get() || id
  end
end
