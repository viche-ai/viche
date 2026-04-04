defmodule Viche.Auth do
  @moduledoc """
  Context module for token-based authentication.

  Manages magic link tokens (single-use, 15 min TTL) and API tokens
  (long-lived, revocable). Only SHA-256 hashes are stored in the database;
  raw tokens are returned once at creation time.
  """

  import Ecto.Query

  alias Viche.Accounts
  alias Viche.Accounts.AuthToken
  alias Viche.Auth.Email
  alias Viche.Mailer
  alias Viche.Repo

  @magic_link_ttl_minutes 15

  @doc """
  Sends a magic link email for the given email address.

  If no user exists with this email, one is created automatically.
  An optional `attrs` map can supply additional fields (e.g. `:name`,
  `:username`) used when creating a new user.

  Returns `{:ok, user}` on success or `{:error, changeset}` if user
  creation fails (e.g. duplicate username).
  """
  @spec send_magic_link(String.t(), map()) ::
          {:ok, Accounts.User.t()} | {:error, Ecto.Changeset.t()}
  def send_magic_link(email, attrs \\ %{}) do
    email = String.downcase(email)

    case Accounts.get_user_by_email(email) do
      nil ->
        case Accounts.create_user(Map.put(attrs, :email, email)) do
          {:ok, user} ->
            send_magic_link_email(user, email)

          {:error, changeset} ->
            {:error, changeset}
        end

      user ->
        send_magic_link_email(user, email)
    end
  end

  defp send_magic_link_email(user, email) do
    {:ok, raw_token, _auth_token} = create_magic_link_token(user.id)

    base = Application.get_env(:viche, :app_url, "http://localhost:4000")
    url = "#{base}/verify?token=#{raw_token}"

    if Application.get_env(:viche, :env, Mix.env()) == :dev do
      require Logger
      Logger.debug("\n\n  [magic link] #{url}\n")
    end

    Task.start(fn ->
      Email.magic_link(email, url)
      |> Mailer.deliver()
    end)

    {:ok, user}
  end

  @api_token_ttl_days 365
  @token_byte_size 32

  @doc """
  Creates a magic link token for the given user.

  Returns `{:ok, raw_token, auth_token}` on success.
  The raw token is shown once and never stored.
  """
  @spec create_magic_link_token(Ecto.UUID.t()) :: {:ok, String.t(), AuthToken.t()}
  def create_magic_link_token(user_id) do
    create_token(user_id, "magic_link", @magic_link_ttl_minutes, :minutes)
  end

  @doc """
  Checks whether a magic link token is valid (not expired, not yet used)
  without consuming it. Useful for previewing validity before the user
  confirms.

  Returns `:ok` or `:error`.
  """
  @spec check_magic_link_token(String.t()) :: :ok | :error
  def check_magic_link_token(raw_token) do
    hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from t in AuthToken,
        where:
          t.token_hash == ^hash and
            t.context == "magic_link" and
            is_nil(t.used_at) and
            t.expires_at > ^now

    case Repo.one(query) do
      nil -> :error
      _token -> :ok
    end
  end

  @doc """
  Verifies and consumes a magic link token. Returns the token record if valid
  (not expired, not yet used). Marks it as used atomically.

  Returns `{:ok, auth_token}` or `{:error, :invalid_token}`.
  """
  @spec verify_magic_link_token(String.t()) :: {:ok, AuthToken.t()} | {:error, :invalid_token}
  def verify_magic_link_token(raw_token) do
    hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from t in AuthToken,
        where:
          t.token_hash == ^hash and
            t.context == "magic_link" and
            is_nil(t.used_at) and
            t.expires_at > ^now

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      token ->
        {:ok, _} =
          token
          |> Ecto.Changeset.change(used_at: DateTime.truncate(now, :second))
          |> Repo.update()

        {:ok, Repo.reload!(token)}
    end
  end

  @doc """
  Creates a long-lived API token for the given user.

  Returns `{:ok, raw_token, auth_token}`. The raw token is shown once.
  """
  @spec create_api_token(Ecto.UUID.t()) :: {:ok, String.t(), AuthToken.t()}
  def create_api_token(user_id) do
    create_token(user_id, "api", @api_token_ttl_days, :days)
  end

  @doc """
  Immediately revokes an API token by setting `used_at` to now.

  Returns `{:ok, auth_token}` or `{:error, :not_found}`.
  """
  @spec revoke_api_token(Ecto.UUID.t()) :: {:ok, AuthToken.t()} | {:error, :not_found}
  def revoke_api_token(token_id) do
    now = DateTime.utc_now()

    query =
      from t in AuthToken,
        where: t.id == ^token_id and t.context == "api" and is_nil(t.used_at)

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      token ->
        {:ok, updated} =
          token
          |> Ecto.Changeset.change(used_at: DateTime.truncate(now, :second))
          |> Repo.update()

        {:ok, updated}
    end
  end

  @doc """
  Rotates an API token: revokes the old one and creates a new one in a single transaction.

  Returns `{:ok, raw_token, new_auth_token}` or `{:error, :not_found}`.
  """
  @spec rotate_api_token(Ecto.UUID.t()) ::
          {:ok, String.t(), AuthToken.t()} | {:error, :not_found}
  def rotate_api_token(token_id) do
    Repo.transaction(fn ->
      case revoke_api_token(token_id) do
        {:ok, old_token} ->
          {:ok, raw, new_token} = create_api_token(old_token.user_id)
          {raw, new_token}

        {:error, :not_found} ->
          Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, {raw, new_token}} -> {:ok, raw, new_token}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active (non-revoked, non-expired) API tokens for a user.
  """
  @spec list_api_tokens(Ecto.UUID.t()) :: [AuthToken.t()]
  def list_api_tokens(user_id) do
    now = DateTime.utc_now()

    from(t in AuthToken,
      where:
        t.user_id == ^user_id and
          t.context == "api" and
          is_nil(t.used_at) and
          t.expires_at > ^now,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Validates a raw API token. Returns the token record if valid.
  """
  @spec verify_api_token(String.t()) :: {:ok, AuthToken.t()} | {:error, :invalid_token}
  def verify_api_token(raw_token) do
    hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from t in AuthToken,
        where:
          t.token_hash == ^hash and
            t.context == "api" and
            is_nil(t.used_at) and
            t.expires_at > ^now

    case Repo.one(query) do
      nil -> {:error, :invalid_token}
      token -> {:ok, token}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp create_token(user_id, context, ttl_amount, ttl_unit) do
    raw_token = generate_token()
    hash = hash_token(raw_token)
    expires_at = compute_expiry(ttl_amount, ttl_unit)

    {:ok, auth_token} =
      %AuthToken{}
      |> AuthToken.changeset(%{
        user_id: user_id,
        token_hash: hash,
        context: context,
        expires_at: expires_at
      })
      |> Repo.insert()

    {:ok, raw_token, auth_token}
  end

  defp generate_token do
    @token_byte_size
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(raw_token) do
    :sha256
    |> :crypto.hash(raw_token)
    |> Base.encode16(case: :lower)
  end

  defp compute_expiry(amount, :minutes) do
    DateTime.utc_now()
    |> DateTime.add(amount * 60, :second)
    |> DateTime.truncate(:second)
  end

  defp compute_expiry(amount, :days) do
    DateTime.utc_now()
    |> DateTime.add(amount * 86_400, :second)
    |> DateTime.truncate(:second)
  end
end
