defmodule Viche.Registries.Registry do
  @moduledoc """
  Schema for the registries table.

  Each registry represents a private namespace that users can create
  to host their agents in isolation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          is_private: boolean() | nil,
          owner_id: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "registries" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :is_private, :boolean, default: true

    belongs_to :owner, Viche.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @slug_regex ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/

  @doc false
  def changeset(registry, attrs) do
    registry
    |> cast(attrs, [:name, :slug, :description, :is_private, :owner_id])
    |> validate_required([:name, :slug, :is_private, :owner_id])
    |> validate_format(:name, ~r/^[a-zA-Z0-9][a-zA-Z0-9 -]{1,50}$/,
      message: "must be 2-50 characters, letters, numbers, spaces and hyphens only"
    )
    |> downcase_slug()
    |> validate_format(:slug, @slug_regex,
      message:
        "must be 3-50 characters, lowercase letters, numbers, and hyphens only, cannot end with a hyphen"
    )
    |> validate_length(:slug, min: 3, max: 50)
    |> validate_length(:description, max: 280)
    |> unique_constraint(:slug)
  end

  defp downcase_slug(%Ecto.Changeset{changes: %{slug: slug}} = changeset) do
    change(changeset, slug: String.downcase(slug))
  end

  defp downcase_slug(changeset), do: changeset
end
