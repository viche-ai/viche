defmodule Viche.Telegram do
  @moduledoc """
  Context module for Telegram-linked agents and pairing flow.
  """

  import Ecto.Query

  alias Viche.Agents
  alias Viche.Registries
  alias Viche.Registries.Registry
  alias Viche.Repo
  alias Viche.Telegram.AgentLink
  alias Viche.Telegram.PairingToken

  @pairing_ttl_minutes 15
  @token_byte_size 32

  @type agent_link_attrs :: %{
          required(:agent_id) => String.t(),
          required(:bot_id) => integer(),
          required(:telegram_user_id) => integer(),
          required(:chat_id) => integer(),
          optional(:telegram_username) => String.t(),
          optional(:telegram_name) => String.t()
        }

  @spec create_agent_link(agent_link_attrs()) ::
          {:ok, AgentLink.t()} | {:error, Ecto.Changeset.t()}
  def create_agent_link(attrs) do
    %AgentLink{}
    |> AgentLink.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_agent_link(String.t()) :: AgentLink.t() | nil
  def get_agent_link(agent_id) when is_binary(agent_id) do
    Repo.get_by(AgentLink, agent_id: agent_id)
  end

  @spec get_agent_link_for_user(integer(), integer()) :: AgentLink.t() | nil
  def get_agent_link_for_user(bot_id, telegram_user_id)
      when is_integer(bot_id) and is_integer(telegram_user_id) do
    Repo.get_by(AgentLink, bot_id: bot_id, telegram_user_id: telegram_user_id)
  end

  @spec list_agent_links() :: [AgentLink.t()]
  def list_agent_links do
    from(link in AgentLink, preload: [:agent], order_by: [desc: link.inserted_at])
    |> Repo.all()
  end

  @spec delete_agent_link(String.t()) :: :ok
  def delete_agent_link(agent_id) when is_binary(agent_id) do
    from(link in AgentLink, where: link.agent_id == ^agent_id)
    |> Repo.delete_all()

    :ok
  end

  @spec create_pairing_token(String.t()) ::
          {:ok, String.t()} | {:error, :agent_not_found | Ecto.Changeset.t()}
  def create_pairing_token(agent_id) when is_binary(agent_id) do
    case Agents.get_agent_record(agent_id) do
      nil ->
        {:error, :agent_not_found}

      _record ->
        raw_token = generate_raw_token()
        token_hash = hash_token(raw_token)
        expires_at = DateTime.add(DateTime.utc_now(), @pairing_ttl_minutes, :minute)

        insert_pairing_token(agent_id, raw_token, token_hash, expires_at)
        |> case do
          {:ok, token} -> {:ok, token}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec get_valid_pairing(String.t()) ::
          {:ok, PairingToken.t(), AgentLink.t()} | {:error, :invalid_token}
  def get_valid_pairing(raw_token) when is_binary(raw_token) do
    now = DateTime.utc_now()
    token_hash = hash_token(raw_token)

    query =
      from(token in PairingToken,
        where:
          token.token_hash == ^token_hash and
            is_nil(token.consumed_at) and
            token.expires_at > ^now
      )

    case Repo.one(query) do
      %PairingToken{} = token ->
        case get_agent_link(token.agent_id) do
          %AgentLink{} = link -> {:ok, token, link}
          nil -> {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  @spec available_registries_for_user(String.t()) :: [Registry.t()]
  def available_registries_for_user(user_id) when is_binary(user_id) do
    owned = Registries.list_user_registries(user_id)

    member_registries =
      user_id
      |> Registries.list_user_memberships()
      |> Enum.map(&Registries.get_registry/1)
      |> Enum.reject(&is_nil/1)

    (owned ++ member_registries)
    |> Enum.uniq_by(& &1.id)
  end

  @spec pair_agent(String.t(), String.t(), [String.t()]) ::
          {:ok, %{agent_id: String.t(), joined_registries: [String.t()]}}
          | {:error, :invalid_token | :already_claimed | :agent_not_found | :not_allowed_registry}
  def pair_agent(raw_token, user_id, registry_ids)
      when is_binary(raw_token) and is_binary(user_id) and is_list(registry_ids) do
    allowed_registry_ids =
      user_id
      |> available_registries_for_user()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    selected_registry_ids =
      registry_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case Enum.all?(selected_registry_ids, &MapSet.member?(allowed_registry_ids, &1)) do
      false -> {:error, :not_allowed_registry}
      true -> run_pairing(raw_token, user_id, selected_registry_ids)
    end
  end

  @spec pair_url(String.t()) :: String.t()
  def pair_url(raw_token) do
    "#{Viche.Config.app_url()}/telegram/pair?token=#{raw_token}"
  end

  @spec pairing_enabled?() :: boolean()
  def pairing_enabled? do
    Agents.require_auth?()
  end

  @spec deregister_linked_agent(String.t()) :: :ok | {:error, :agent_not_found}
  def deregister_linked_agent(agent_id) when is_binary(agent_id) do
    delete_agent_link(agent_id)
    Agents.deregister(agent_id)
  end

  @spec claim_agent(String.t(), String.t()) :: :ok | {:error, :already_claimed | :agent_not_found}
  defp claim_agent(agent_id, user_id) do
    Agents.claim_agent(agent_id, user_id)
  end

  @spec consume_pairing_token(PairingToken.t()) ::
          {:ok, PairingToken.t()} | {:error, :invalid_token}
  defp consume_pairing_token(%PairingToken{id: id} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(
           from(t in PairingToken, where: t.id == ^id and is_nil(t.consumed_at)),
           set: [consumed_at: now]
         ) do
      {1, _} -> {:ok, %{token | consumed_at: now}}
      _ -> {:error, :invalid_token}
    end
  end

  @spec join_selected_registries(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp join_selected_registries(_agent_id, []), do: :ok

  defp join_selected_registries(agent_id, registry_ids) do
    Enum.reduce_while(registry_ids, :ok, fn registry_id, :ok ->
      case Agents.join_registry(agent_id, registry_id) do
        {:ok, _agent} -> {:cont, :ok}
        {:error, :already_in_registry} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec generate_raw_token() :: String.t()
  defp generate_raw_token do
    @token_byte_size
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec hash_token(String.t()) :: String.t()
  defp hash_token(raw_token) do
    :sha256
    |> :crypto.hash(raw_token)
    |> Base.encode16(case: :lower)
  end

  @spec run_pairing(String.t(), String.t(), [String.t()]) ::
          {:ok, %{agent_id: String.t(), joined_registries: [String.t()]}}
          | {:error, :invalid_token | :already_claimed | :agent_not_found | :not_allowed_registry}
  defp run_pairing(raw_token, user_id, selected_registry_ids) do
    with {:ok, token, link} <- get_valid_pairing(raw_token),
         :ok <- claim_agent(link.agent_id, user_id),
         :ok <- sync_paired_registries(link.agent_id, selected_registry_ids),
         {:ok, _} <- consume_pairing_token(token) do
      {:ok, %{agent_id: link.agent_id, joined_registries: selected_registry_ids}}
    end
  end

  @spec sync_paired_registries(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp sync_paired_registries(agent_id, selected_registry_ids) do
    case ensure_agent_reactivated(agent_id) do
      :ok ->
        case join_selected_registries(agent_id, selected_registry_ids) do
          :ok -> leave_global_registry(agent_id)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ensure_agent_reactivated(String.t()) :: :ok | {:error, :agent_not_found}
  defp ensure_agent_reactivated(agent_id) do
    case Agents.reactivate_agent(agent_id, connection_type: :websocket) do
      {:ok, _agent} -> Agents.websocket_connected(agent_id)
      {:error, :agent_not_found} -> {:error, :agent_not_found}
    end
  end

  @spec leave_global_registry(String.t()) :: :ok | {:error, term()}
  defp leave_global_registry(agent_id) do
    case Agents.deregister_from_registries(agent_id, %{registry: "global"}) do
      {:ok, _agent} -> :ok
      {:error, :not_in_registry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec expire_active_pairing_tokens(String.t()) :: :ok
  defp expire_active_pairing_tokens(agent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(token in PairingToken,
        where: token.agent_id == ^agent_id and is_nil(token.consumed_at)
      ),
      set: [consumed_at: now]
    )

    :ok
  end

  @spec insert_pairing_token(String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  defp insert_pairing_token(agent_id, raw_token, token_hash, expires_at) do
    Repo.transaction(fn ->
      expire_active_pairing_tokens(agent_id)

      case Repo.insert(
             PairingToken.changeset(%PairingToken{}, %{
               agent_id: agent_id,
               token_hash: token_hash,
               expires_at: expires_at
             })
           ) do
        {:ok, _token} -> raw_token
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
