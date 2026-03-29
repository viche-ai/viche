defmodule Viche.AuthTest do
  use Viche.DataCase, async: true

  alias Viche.Accounts.User
  alias Viche.Auth

  setup do
    {:ok, user} =
      %User{}
      |> User.changeset(%{email: "test@example.com"})
      |> Repo.insert()

    %{user: user}
  end

  describe "create_magic_link_token/1" do
    test "creates a token and returns the raw value", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_magic_link_token(user.id)

      assert is_binary(raw_token)
      assert byte_size(raw_token) > 0
      assert auth_token.context == "magic_link"
      assert auth_token.user_id == user.id
      assert is_nil(auth_token.used_at)
    end

    test "stores only the hash, not the raw token", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_magic_link_token(user.id)

      refute auth_token.token_hash == raw_token
      expected_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      assert auth_token.token_hash == expected_hash
    end

    test "magic link expires in ~15 minutes", %{user: user} do
      {:ok, _raw, auth_token} = Auth.create_magic_link_token(user.id)

      diff = DateTime.diff(auth_token.expires_at, DateTime.utc_now(), :second)
      assert diff >= 14 * 60
      assert diff <= 16 * 60
    end
  end

  describe "check_magic_link_token/1" do
    test "returns :ok for a valid token", %{user: user} do
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      assert :ok = Auth.check_magic_link_token(raw_token)
    end

    test "returns :error for an invalid token" do
      assert :error = Auth.check_magic_link_token("bogus-token")
    end

    test "returns :error for an expired token", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_magic_link_token(user.id)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      auth_token
      |> Ecto.Changeset.change(expires_at: DateTime.truncate(past, :second))
      |> Repo.update!()

      assert :error = Auth.check_magic_link_token(raw_token)
    end

    test "returns :ok even after check (does not consume)", %{user: user} do
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      assert :ok = Auth.check_magic_link_token(raw_token)
      assert :ok = Auth.check_magic_link_token(raw_token)
    end
  end

  describe "verify_magic_link_token/1" do
    test "verifies a valid token and marks it as used", %{user: user} do
      {:ok, raw_token, _auth_token} = Auth.create_magic_link_token(user.id)

      assert {:ok, verified} = Auth.verify_magic_link_token(raw_token)
      assert verified.user_id == user.id
      refute is_nil(verified.used_at)
    end

    test "rejects an already-used token", %{user: user} do
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      assert {:ok, _} = Auth.verify_magic_link_token(raw_token)
      assert {:error, :invalid_token} = Auth.verify_magic_link_token(raw_token)
    end

    test "rejects an expired token", %{user: user} do
      # Create a token, then manually expire it
      {:ok, raw_token, auth_token} = Auth.create_magic_link_token(user.id)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      auth_token
      |> Ecto.Changeset.change(expires_at: DateTime.truncate(past, :second))
      |> Repo.update!()

      assert {:error, :invalid_token} = Auth.verify_magic_link_token(raw_token)
    end

    test "rejects an invalid token" do
      assert {:error, :invalid_token} = Auth.verify_magic_link_token("bogus-token")
    end
  end

  describe "create_api_token/1" do
    test "creates a long-lived API token", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_api_token(user.id)

      assert is_binary(raw_token)
      assert auth_token.context == "api"
      assert auth_token.user_id == user.id
      assert is_nil(auth_token.used_at)

      diff = DateTime.diff(auth_token.expires_at, DateTime.utc_now(), :day)
      assert diff >= 364
    end
  end

  describe "revoke_api_token/1" do
    test "revokes an active API token", %{user: user} do
      {:ok, _raw, auth_token} = Auth.create_api_token(user.id)

      assert {:ok, revoked} = Auth.revoke_api_token(auth_token.id)
      refute is_nil(revoked.used_at)
    end

    test "returns error when token not found" do
      assert {:error, :not_found} = Auth.revoke_api_token(Ecto.UUID.generate())
    end

    test "returns error when token already revoked", %{user: user} do
      {:ok, _raw, auth_token} = Auth.create_api_token(user.id)

      assert {:ok, _} = Auth.revoke_api_token(auth_token.id)
      assert {:error, :not_found} = Auth.revoke_api_token(auth_token.id)
    end

    test "revoked token cannot be verified", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_api_token(user.id)

      Auth.revoke_api_token(auth_token.id)
      assert {:error, :invalid_token} = Auth.verify_api_token(raw_token)
    end
  end

  describe "rotate_api_token/1" do
    test "revokes old token and creates a new one", %{user: user} do
      {:ok, old_raw, old_token} = Auth.create_api_token(user.id)

      {:ok, new_raw, new_token} = Auth.rotate_api_token(old_token.id)

      refute old_raw == new_raw
      refute old_token.id == new_token.id
      assert new_token.user_id == user.id
      assert new_token.context == "api"

      # Old token is revoked
      assert {:error, :invalid_token} = Auth.verify_api_token(old_raw)
      # New token is valid
      assert {:ok, _} = Auth.verify_api_token(new_raw)
    end

    test "returns error when token not found" do
      assert {:error, :not_found} = Auth.rotate_api_token(Ecto.UUID.generate())
    end
  end

  describe "list_api_tokens/1" do
    test "returns active API tokens for a user", %{user: user} do
      {:ok, _, _} = Auth.create_api_token(user.id)
      {:ok, _, token2} = Auth.create_api_token(user.id)

      tokens = Auth.list_api_tokens(user.id)
      assert length(tokens) == 2

      # Revoke one
      Auth.revoke_api_token(token2.id)
      tokens = Auth.list_api_tokens(user.id)
      assert length(tokens) == 1
    end

    test "does not return magic link tokens", %{user: user} do
      {:ok, _, _} = Auth.create_magic_link_token(user.id)
      {:ok, _, _} = Auth.create_api_token(user.id)

      tokens = Auth.list_api_tokens(user.id)
      assert length(tokens) == 1
      assert hd(tokens).context == "api"
    end

    test "does not return expired tokens", %{user: user} do
      {:ok, _, auth_token} = Auth.create_api_token(user.id)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      auth_token
      |> Ecto.Changeset.change(expires_at: DateTime.truncate(past, :second))
      |> Repo.update!()

      assert Auth.list_api_tokens(user.id) == []
    end

    test "returns empty list for user with no tokens", %{user: _user} do
      {:ok, other_user} =
        %User{}
        |> User.changeset(%{email: "other@example.com"})
        |> Repo.insert()

      assert Auth.list_api_tokens(other_user.id) == []
    end
  end

  describe "verify_api_token/1" do
    test "verifies a valid API token", %{user: user} do
      {:ok, raw_token, _} = Auth.create_api_token(user.id)

      assert {:ok, token} = Auth.verify_api_token(raw_token)
      assert token.context == "api"
      assert token.user_id == user.id
    end

    test "rejects invalid token" do
      assert {:error, :invalid_token} = Auth.verify_api_token("not-a-real-token")
    end
  end
end
