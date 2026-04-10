defmodule Viche.Registries do
  @moduledoc """
  Context module for managing private registries.

  Private registries allow users to create isolated namespaces for their agents.
  Each registry has a unique slug that forms part of the well-known URL.
  """

  import Ecto.Query

  alias Viche.Registries.Registry
  alias Viche.Registries.RegistryInvitation
  alias Viche.Registries.RegistryMember
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
    base_url = Application.get_env(:viche, :base_url, "https://viche.ai")
    "#{base_url}/.well-known/agent-registry?token=#{id}"
  end

  # ---------------------------------------------------------------------------
  # Invitations
  # ---------------------------------------------------------------------------

  @token_byte_size 32

  @doc """
  Creates an invitation for the given email to join a registry.
  """
  @spec create_invitation(String.t(), String.t(), String.t()) ::
          {:ok, RegistryInvitation.t()} | {:error, Ecto.Changeset.t()}
  def create_invitation(registry_id, invited_by_id, email) do
    token =
      @token_byte_size
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    %RegistryInvitation{registry_id: registry_id, invited_by_id: invited_by_id}
    |> RegistryInvitation.changeset(%{
      email: String.downcase(email),
      token: token
    })
    |> Repo.insert()
  end

  @doc """
  Looks up a pending invitation by its token.
  """
  @spec get_invitation_by_token(String.t()) :: RegistryInvitation.t() | nil
  def get_invitation_by_token(token) do
    from(i in RegistryInvitation,
      where: i.token == ^token and is_nil(i.accepted_at),
      preload: [:registry]
    )
    |> Repo.one()
  end

  @doc """
  Accepts an invitation: marks it as accepted and adds the user as a registry member.
  """
  @spec accept_invitation(RegistryInvitation.t(), String.t()) ::
          {:ok, RegistryMember.t()} | {:error, Ecto.Changeset.t()}
  def accept_invitation(%RegistryInvitation{} = invitation, user_id) do
    Repo.transaction(fn ->
      {:ok, _} =
        invitation
        |> Ecto.Changeset.change(
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )
        |> Repo.update()

      case add_member(invitation.registry_id, user_id) do
        {:ok, member} -> member
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Members
  # ---------------------------------------------------------------------------

  @doc """
  Adds a user as a member of a registry. No-op if already a member.
  """
  @spec add_member(String.t(), String.t()) ::
          {:ok, RegistryMember.t()} | {:error, Ecto.Changeset.t()}
  def add_member(registry_id, user_id) do
    %RegistryMember{registry_id: registry_id, user_id: user_id}
    |> RegistryMember.changeset(%{})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:registry_id, :user_id])
  end

  @doc """
  Returns registry IDs where the given user is a member (not owner).
  """
  @spec list_user_memberships(String.t()) :: [String.t()]
  def list_user_memberships(user_id) do
    from(m in RegistryMember,
      where: m.user_id == ^user_id,
      select: m.registry_id
    )
    |> Repo.all()
  end

  # Private helpers

  defp maybe_preload_owner(nil), do: nil
  defp maybe_preload_owner(registry), do: Repo.preload(registry, :owner)
end
