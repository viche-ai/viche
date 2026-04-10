defmodule Viche.Registries do
  @moduledoc """
  Context module for managing private registries.

  Private registries allow users to create isolated namespaces for their agents.
  Each registry has a unique slug that forms part of the well-known URL.
  """

  import Ecto.Query

  alias Viche.Registries.Registry
  alias Viche.Repo

  @doc """
  Returns all registries owned by the given user.
  """
  @spec list_user_registries(String.t()) :: [Registry.t()]
  def list_user_registries(user_id) do
    from(r in Registry, where: r.owner_id == ^user_id, order_by: [desc: r.inserted_at])
    |> Repo.all()
  end

  @doc """
  Returns a registry by its ID.
  """
  @spec get_registry(String.t()) :: Registry.t() | nil
  def get_registry(id) do
    Repo.get(Registry, id)
  end

  @doc """
  Returns a registry by its ID with owner preloaded.
  """
  @spec get_registry_with_owner(String.t()) :: Registry.t() | nil
  def get_registry_with_owner(id) do
    id
    |> Repo.get(Registry)
    |> maybe_preload_owner()
  end

  @doc """
  Returns a registry by its slug.
  """
  @spec get_registry_by_slug(String.t()) :: Registry.t() | nil
  def get_registry_by_slug(slug) do
    Repo.get_by(Registry, slug: slug)
  end

  @doc """
  Returns a registry by ID, only if it belongs to the given user.
  Use this for authorization checks.
  """
  @spec get_user_registry(String.t(), String.t()) :: Registry.t() | nil
  def get_user_registry(id, user_id) do
    Repo.get_by(Registry, id: id, owner_id: user_id)
  end

  @doc """
  Checks if a slug is available (not already taken).
  """
  @spec slug_available?(String.t()) :: boolean()
  def slug_available?(slug) when is_binary(slug) do
    slug = String.downcase(slug)
    Repo.get_by(Registry, slug: slug) == nil
  end

  @doc """
  Checks if the given user owns the registry.
  """
  @spec user_owns_registry?(String.t() | nil, Registry.t()) :: boolean()
  def user_owns_registry?(user_id, %Registry{owner_id: owner_id}) do
    user_id == owner_id
  end

  @doc """
  Creates a new registry for the given user.
  """
  @spec create_registry(String.t(), map()) ::
          {:ok, Registry.t()} | {:error, Ecto.Changeset.t()}
  def create_registry(owner_id, attrs) do
    %Registry{owner_id: owner_id}
    |> Registry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a registry. Only the owner should call this.
  """
  @spec update_registry(Registry.t(), map()) ::
          {:ok, Registry.t()} | {:error, Ecto.Changeset.t()}
  def update_registry(%Registry{} = registry, attrs) do
    registry
    |> Registry.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a registry. Only the owner should call this.
  """
  @spec delete_registry(Registry.t()) :: {:ok, Registry.t()} | {:error, Ecto.Changeset.t()}
  def delete_registry(%Registry{} = registry) do
    Repo.delete(registry)
  end

  @doc """
  Returns the well-known URL for a registry.
  """
  @spec well_known_url(Registry.t()) :: String.t()
  def well_known_url(%Registry{id: id}) do
    "#{Viche.Config.app_url()}/.well-known/agent-registry?token=#{id}"
  end

  # Private helpers

  defp maybe_preload_owner(nil), do: nil
  defp maybe_preload_owner(registry), do: Repo.preload(registry, :owner)
end
