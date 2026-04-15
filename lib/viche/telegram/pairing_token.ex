defmodule Viche.Telegram.PairingToken do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: binary() | nil,
          token_hash: String.t() | nil,
          expires_at: DateTime.t() | nil,
          consumed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "telegram_pairing_tokens" do
    field :token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    belongs_to :agent, Viche.Agents.AgentRecord

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:agent_id, :token_hash, :expires_at, :consumed_at])
    |> validate_required([:agent_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
