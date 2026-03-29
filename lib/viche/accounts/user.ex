defmodule Viche.Accounts.User do
  @moduledoc """
  Schema for the users table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :name, :string

    has_many :auth_tokens, Viche.Accounts.AuthToken

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end
end
