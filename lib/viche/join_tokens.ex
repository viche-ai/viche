defmodule Viche.JoinTokens do
  @moduledoc "Simple in-memory store for join tokens generated from /demo QR scans."
  @table :join_tokens

  def init do
    :ets.new(@table, [:named_table, :public, :set])
  end

  def create(hash) do
    token = "viche_tk_#{hash}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    expires_at = DateTime.add(DateTime.utc_now(), 48 * 3600, :second)

    :ets.insert(@table, {hash, %{token: token, created_at: DateTime.utc_now(), expires_at: expires_at}})

    token
  end

  def get(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, data}] ->
        if DateTime.compare(DateTime.utc_now(), data.expires_at) == :lt do
          {:ok, data}
        else
          :ets.delete(@table, hash)
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def valid?(hash) do
    case get(hash) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
