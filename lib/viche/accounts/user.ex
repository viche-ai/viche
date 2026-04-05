defmodule Viche.Accounts.User do
  @moduledoc """
  Schema for the users table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          username: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field :email, :string
    field :name, :string
    field :username, :string

    has_many :auth_tokens, Viche.Accounts.AuthToken
    has_many :agents, Viche.Agents.AgentRecord
    has_many :registries, Viche.Registries.Registry, foreign_key: :owner_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :username])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]{1,30}$/,
      message: "must be 1–30 characters, letters, numbers, and underscores only"
    )
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end
end
