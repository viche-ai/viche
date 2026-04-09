defmodule Viche.Accounts do
  @moduledoc """
  Context module for user account management.

  Provides functions to create users, look them up by email, and resolve
  users from authentication tokens.
  """

  import Ecto.Query

  alias Viche.Accounts.{AuthToken, User}
  alias Viche.Repo

  @doc """
  Creates a new user with the given attributes.

  ## Examples

      iex> Viche.Accounts.create_user(%{email: "alice@example.com"})
      {:ok, %User{}}

      iex> Viche.Accounts.create_user(%{email: "bad"})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a user by email (case-insensitive).

  Returns `nil` if no user is found.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Checks whether a username is already taken.
  """
  @spec username_taken?(String.t()) :: boolean()
  def username_taken?(username) when is_binary(username) do
    Repo.get_by(User, username: username) != nil
  end

  @doc """
  Fetches a user associated with a valid (non-expired, non-revoked) token hash.

  This is useful for resolving the current user from an API token during
  request authentication.

  Returns `nil` if the token is invalid, expired, or revoked.
  """
  @spec get_user_by_token(String.t(), String.t()) :: User.t() | nil
  def get_user_by_token(raw_token, context) when context in ~w(magic_link api) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from t in AuthToken,
        join: u in assoc(t, :user),
        where:
          t.token_hash == ^token_hash and
            t.context == ^context and
            is_nil(t.used_at) and
            t.expires_at > ^now,
        select: u

    Repo.one(query)
  end

  @doc """
  Fetches the user associated with an auth token record.
  """
  @spec get_user_by_token_record(AuthToken.t()) :: User.t() | nil
  def get_user_by_token_record(%AuthToken{user_id: user_id}) do
    Repo.get(User, user_id)
  end

  defp hash_token(raw_token) do
    :sha256
    |> :crypto.hash(raw_token)
    |> Base.encode16(case: :lower)
  end
end
