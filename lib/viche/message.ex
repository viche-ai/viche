defmodule Viche.Message do
  @moduledoc """
  Represents a message sent to an agent's inbox.

  Messages are fire-and-forget: the sender receives a message ID immediately
  and the message is appended to the target agent's in-memory inbox.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          from: String.t(),
          body: String.t(),
          sent_at: DateTime.t(),
          in_reply_to: String.t() | nil,
          conversation_id: String.t() | nil
        }

  defstruct [:id, :type, :from, :body, :sent_at, :in_reply_to, :conversation_id]

  @valid_types ~w(task result ping)

  @doc """
  Returns the list of valid message types.
  """
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

  @doc """
  Returns true if the given type string is a valid message type.
  """
  @spec valid_type?(String.t()) :: boolean()
  def valid_type?(type), do: type in @valid_types
end
