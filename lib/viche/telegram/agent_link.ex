defmodule Viche.Telegram.AgentLink do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: binary() | nil,
          bot_id: integer() | nil,
          telegram_user_id: integer() | nil,
          chat_id: integer() | nil,
          telegram_username: String.t() | nil,
          telegram_name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "telegram_agent_links" do
    field :bot_id, :integer
    field :telegram_user_id, :integer
    field :chat_id, :integer
    field :telegram_username, :string
    field :telegram_name, :string

    belongs_to :agent, Viche.Agents.AgentRecord

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :agent_id,
      :bot_id,
      :telegram_user_id,
      :chat_id,
      :telegram_username,
      :telegram_name
    ])
    |> validate_required([:agent_id, :bot_id, :telegram_user_id, :chat_id])
    |> unique_constraint(:agent_id)
    |> unique_constraint([:bot_id, :telegram_user_id])
  end
end
