defmodule Viche.RegistriesTest do
  use Viche.DataCase, async: true

  alias Viche.Accounts
  alias Viche.Registries
  alias Viche.Registries.Registry

  setup do
    {:ok, user} = Accounts.create_user(%{email: "test#{:rand.uniform(1_000_000)}@example.com"})
    %{user: user}
  end

  describe "create_registry/2" do
    test "creates a registry with valid attributes", %{user: user} do
      attrs = %{
        "name" => "My Private Network",
        "slug" => "my-private-network",
        "description" => "A private network for my agents"
      }

      assert {:ok, %Registry{} = registry} = Registries.create_registry(user.id, attrs)
      assert registry.name == "My Private Network"
      assert registry.slug == "my-private-network"
      assert registry.description == "A private network for my agents"
      assert registry.is_private == true
      assert registry.owner_id == user.id
    end

    test "creates a registry without description", %{user: user} do
      attrs = %{"name" => "Minimal Registry", "slug" => "minimal-registry"}

      assert {:ok, %Registry{} = registry} = Registries.create_registry(user.id, attrs)
      assert registry.description == nil
    end

    test "downcases slug automatically", %{user: user} do
      attrs = %{"name" => "Test Registry", "slug" => "My-Test-Network"}

      assert {:ok, %Registry{} = registry} = Registries.create_registry(user.id, attrs)
      assert registry.slug == "my-test-network"
    end

    test "rejects invalid name", %{user: user} do
      attrs = %{"name" => "", "slug" => "valid-slug"}

      assert {:error, changeset} = Registries.create_registry(user.id, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid slug format (spaces)", %{user: user} do
      attrs = %{"name" => "Valid Name", "slug" => "has spaces"}

      assert {:error, changeset} = Registries.create_registry(user.id, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects slug that's too short", %{user: user} do
      attrs = %{"name" => "Valid Name", "slug" => "ab"}

      assert {:error, changeset} = Registries.create_registry(user.id, attrs)
      assert %{slug: [_ | _]} = errors_on(changeset)
    end

    test "rejects slug with trailing hyphen", %{user: user} do
      attrs = %{"name" => "Valid Name", "slug" => "test-"}

      assert {:error, changeset} = Registries.create_registry(user.id, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects slug starting with hyphen", %{user: user} do
      attrs = %{"name" => "Valid Name", "slug" => "-test"}

      assert {:error, changeset} = Registries.create_registry(user.id, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "rejects duplicate slug", %{user: user} do
      attrs = %{"name" => "First Registry", "slug" => "duplicate-test-#{:rand.uniform(10_000)}"}

      assert {:ok, _} = Registries.create_registry(user.id, attrs)

      attrs2 = %{"name" => "Second Registry", "slug" => attrs["slug"]}
      assert {:error, changeset} = Registries.create_registry(user.id, attrs2)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "list_user_registries/1" do
    test "returns only user's registries", %{user: user} do
      # Create a registry first
      {:ok, _} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "test-registry-#{:rand.uniform(100_000)}"
        })

      registries = Registries.list_user_registries(user.id)
      assert registries != []
      assert Enum.all?(registries, &(&1.owner_id == user.id))
    end

    test "orders by inserted_at descending", %{user: user} do
      # Create multiple registries
      {:ok, _} =
        Registries.create_registry(user.id, %{
          "name" => "First Registry",
          "slug" => "first-registry-#{:rand.uniform(100_000)}"
        })

      {:ok, _} =
        Registries.create_registry(user.id, %{
          "name" => "Second Registry",
          "slug" => "second-registry-#{:rand.uniform(100_000)}"
        })

      registries = Registries.list_user_registries(user.id)
      inserted_ats = Enum.map(registries, & &1.inserted_at)

      # Should be descending (newest first)
      assert inserted_ats == Enum.sort(inserted_ats, {:desc, DateTime})
    end
  end

  describe "get_registry/1" do
    test "returns registry by id", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "get-registry-#{:rand.uniform(100_000)}"
        })

      assert found = Registries.get_registry(registry.id)
      assert found.id == registry.id
    end

    test "returns nil for unknown id" do
      assert Registries.get_registry("00000000-0000-0000-0000-000000000000") == nil
    end
  end

  describe "get_registry_by_slug/1" do
    test "returns registry by slug", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "by-slug-test-#{:rand.uniform(100_000)}"
        })

      assert found = Registries.get_registry_by_slug(registry.slug)
      assert found.id == registry.id
    end

    test "returns nil for unknown slug" do
      assert Registries.get_registry_by_slug("nonexistent-slug-xyz") == nil
    end
  end

  describe "get_user_registry/2" do
    test "returns registry when user is owner", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "user-registry-#{:rand.uniform(100_000)}"
        })

      assert found = Registries.get_user_registry(registry.id, user.id)
      assert found.id == registry.id
    end

    test "returns nil when user is not owner", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "other-registry-#{:rand.uniform(100_000)}"
        })

      {:ok, other_user} =
        Accounts.create_user(%{email: "other#{:rand.uniform(100_000)}@example.com"})

      assert Registries.get_user_registry(registry.id, other_user.id) == nil
    end
  end

  describe "slug_available?/1" do
    test "returns false when slug is taken", %{user: user} do
      unique_slug = "taken-slug-#{:rand.uniform(100_000)}"

      {:ok, _} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => unique_slug
        })

      refute Registries.slug_available?(unique_slug)
    end

    test "returns true when slug is available" do
      assert Registries.slug_available?(
               "completely-new-and-unique-slug-#{:rand.uniform(100_000)}"
             )
    end

    test "is case-insensitive", %{user: user} do
      {:ok, _} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "case-insensitive-test"
        })

      refute Registries.slug_available?("CASE-INSENSITIVE-TEST")
    end
  end

  describe "user_owns_registry?/2" do
    test "returns true when user is owner", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "own-test-#{:rand.uniform(100_000)}"
        })

      assert Registries.user_owns_registry?(user.id, registry)
    end

    test "returns false when user is not owner", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "not-own-test-#{:rand.uniform(100_000)}"
        })

      {:ok, other_user} =
        Accounts.create_user(%{email: "other2#{:rand.uniform(100_000)}@example.com"})

      refute Registries.user_owns_registry?(other_user.id, registry)
    end

    test "returns false when user_id is nil", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "nil-user-test-#{:rand.uniform(100_000)}"
        })

      refute Registries.user_owns_registry?(nil, registry)
    end
  end

  describe "update_registry/2" do
    test "updates registry name", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Original Name",
          "slug" => "update-test-#{:rand.uniform(100_000)}"
        })

      assert {:ok, updated} = Registries.update_registry(registry, %{"name" => "New Name"})
      assert updated.name == "New Name"
    end

    test "updates registry description", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "update-desc-test-#{:rand.uniform(100_000)}"
        })

      assert {:ok, updated} =
               Registries.update_registry(registry, %{"description" => "New description"})

      assert updated.description == "New description"
    end
  end

  describe "delete_registry/1" do
    test "deletes the registry", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "To Delete Registry",
          "slug" => "delete-test-#{:rand.uniform(100_000)}"
        })

      assert {:ok, _} = Registries.delete_registry(registry)
      refute Registries.get_registry(registry.id)
    end
  end

  describe "well_known_url/1" do
    test "generates correct URL", %{user: user} do
      {:ok, registry} =
        Registries.create_registry(user.id, %{
          "name" => "Test Registry",
          "slug" => "wellknown-test-#{:rand.uniform(100_000)}"
        })

      url = Registries.well_known_url(registry)
      assert url =~ "/.well-known/agent-registry"
      assert url =~ "token=#{registry.id}"
    end
  end
end
