defmodule Viche.Registries.RegistryInvitation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "registry_invitations" do
    field :email, :string
    field :token, :string
    field :accepted_at, :utc_datetime_usec

    belongs_to :registry, Viche.Registries.Registry
    belongs_to :invited_by, Viche.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :token])
    |> validate_required([:email, :token, :registry_id, :invited_by_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> unique_constraint(:token)
  end
end
