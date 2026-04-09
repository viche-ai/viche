defmodule Viche.Registries.RegistryMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "registry_members" do
    field :role, :string, default: "member"

    belongs_to :registry, Viche.Registries.Registry
    belongs_to :user, Viche.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:registry_id, :user_id, :role])
    |> validate_required([:registry_id, :user_id])
    |> unique_constraint([:registry_id, :user_id])
  end
end
