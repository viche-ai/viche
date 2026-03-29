defmodule Viche.Accounts.AuthToken do
  @moduledoc """
  Schema for the auth_tokens table.

  Tokens are stored as SHA-256 hashes. The raw token is only available
  at creation time and is never persisted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          token_hash: String.t() | nil,
          context: String.t() | nil,
          expires_at: DateTime.t() | nil,
          used_at: DateTime.t() | nil,
          user_id: binary() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "auth_tokens" do
    field :token_hash, :string
    field :context, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, Viche.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @valid_contexts ~w(magic_link api)

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :context, :expires_at, :user_id])
    |> validate_required([:token_hash, :context, :expires_at, :user_id])
    |> validate_inclusion(:context, @valid_contexts)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
