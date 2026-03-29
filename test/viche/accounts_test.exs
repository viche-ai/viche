defmodule Viche.AccountsTest do
  use Viche.DataCase, async: true

  alias Viche.Accounts
  alias Viche.Accounts.User
  alias Viche.Auth

  describe "create_user/1" do
    test "creates a user with valid email" do
      assert {:ok, %User{} = user} = Accounts.create_user(%{email: "alice@example.com"})
      assert user.email == "alice@example.com"
      assert user.id != nil
    end

    test "creates a user with name" do
      assert {:ok, user} = Accounts.create_user(%{email: "bob@example.com", name: "Bob"})
      assert user.name == "Bob"
    end

    test "downcases email" do
      assert {:ok, user} = Accounts.create_user(%{email: "Alice@Example.COM"})
      assert user.email == "alice@example.com"
    end

    test "rejects missing email" do
      assert {:error, changeset} = Accounts.create_user(%{})
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid email format" do
      assert {:error, changeset} = Accounts.create_user(%{email: "not-an-email"})
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "rejects duplicate email" do
      assert {:ok, _} = Accounts.create_user(%{email: "dup@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "dup@example.com"})
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects duplicate email case-insensitively" do
      assert {:ok, _} = Accounts.create_user(%{email: "dup@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "DUP@example.com"})
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_user_by_email/1" do
    test "returns user by email" do
      {:ok, user} = Accounts.create_user(%{email: "find@example.com"})
      assert found = Accounts.get_user_by_email("find@example.com")
      assert found.id == user.id
    end

    test "is case-insensitive" do
      {:ok, user} = Accounts.create_user(%{email: "find@example.com"})
      assert found = Accounts.get_user_by_email("FIND@Example.COM")
      assert found.id == user.id
    end

    test "returns nil for unknown email" do
      assert Accounts.get_user_by_email("nope@example.com") == nil
    end
  end

  describe "get_user_by_token/2" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "token@example.com"})
      %{user: user}
    end

    test "returns user for valid API token", %{user: user} do
      {:ok, raw_token, _} = Auth.create_api_token(user.id)
      assert found = Accounts.get_user_by_token(raw_token, "api")
      assert found.id == user.id
    end

    test "returns user for valid magic link token", %{user: user} do
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)
      assert found = Accounts.get_user_by_token(raw_token, "magic_link")
      assert found.id == user.id
    end

    test "returns nil for invalid token" do
      assert Accounts.get_user_by_token("bogus", "api") == nil
    end

    test "returns nil for revoked token", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_api_token(user.id)
      Auth.revoke_api_token(auth_token.id)
      assert Accounts.get_user_by_token(raw_token, "api") == nil
    end

    test "returns nil for expired token", %{user: user} do
      {:ok, raw_token, auth_token} = Auth.create_api_token(user.id)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      auth_token
      |> Ecto.Changeset.change(expires_at: DateTime.truncate(past, :second))
      |> Repo.update!()

      assert Accounts.get_user_by_token(raw_token, "api") == nil
    end
  end
end
