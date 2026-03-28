defmodule Viche.Release do
  @moduledoc """
  Provides Mix-free tasks that run inside a compiled release.

  These functions are called by the release overlay scripts at deploy time,
  where the Mix toolchain is not available. They load the application
  just enough to execute Ecto migrations and rollbacks.

  Usage from the release binary:

      # Run all pending migrations (called by /app/bin/migrate)
      bin/viche eval Viche.Release.migrate

      # Roll back migrations for a specific repo and version
      bin/viche eval "Viche.Release.rollback(Viche.Repo, 20240101120000)"
  """

  @app :viche

  @doc """
  Runs all pending Ecto migrations for every repo configured in the app.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls back migrations for the given repo to the specified version.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok
  defp load_app do
    Application.load(@app)
  end
end
