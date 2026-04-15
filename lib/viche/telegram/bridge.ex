defmodule Viche.Telegram.Bridge do
  @moduledoc """
  Telegram bridge process for registering Telegram-backed agents and routing messages.
  """

  use GenServer

  require Logger

  alias Viche.Agents
  alias Viche.Telegram
  alias Viche.Telegram.Api

  @message_map_ttl_ms 60 * 60 * 1_000
  @poll_interval_ms 100

  @type user_info :: %{
          agent_id: String.t(),
          name: String.t(),
          capabilities: [String.t()],
          chat_id: integer(),
          telegram_user_id: integer()
        }

  @type pending_state :: :awaiting_name | {:awaiting_capabilities, String.t()}

  @type state :: %{
          bot_token: String.t(),
          bot_id: integer(),
          users: %{integer() => user_info()},
          message_map: %{term() => map()},
          pending: %{integer() => pending_state()},
          last_update_id: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    bot_token = Keyword.fetch!(opts, :bot_token)

    case Api.get_me(bot_token) do
      {:ok, %{"id" => bot_id, "username" => username}} ->
        Logger.info("Telegram bridge started for bot @#{username} (id: #{bot_id})")

        state = %{
          bot_token: bot_token,
          bot_id: bot_id,
          users: %{},
          message_map: %{},
          pending: %{},
          last_update_id: nil
        }

        state = restore_links(state)
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        Logger.error("Telegram bridge failed to start: #{inspect(reason)}")
        {:stop, {:bad_token, reason}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    offset = if state.last_update_id, do: state.last_update_id + 1, else: nil

    state =
      case Api.get_updates(state.bot_token, offset) do
        {:ok, updates} ->
          Enum.reduce(updates, state, &process_update/2)

        {:error, reason} ->
          Logger.warning("Telegram getUpdates failed: #{inspect(reason)}")
          state
      end

    schedule_poll()
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "agent:" <> agent_id,
          event: "new_message",
          payload: payload
        },
        state
      ) do
    case find_user_by_agent_id(state, agent_id) do
      {_telegram_user_id, user} when payload.from != agent_id ->
        {:noreply, forward_to_telegram(user, payload, state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec process_update(map(), state()) :: state()
  defp process_update(%{"update_id" => update_id} = update, state) do
    state = %{state | last_update_id: update_id}

    cond do
      msg = update["message"] -> process_message(msg, state)
      cb = update["callback_query"] -> process_callback_query(cb, state)
      true -> state
    end
  end

  @spec process_message(map(), state()) :: state()
  defp process_message(%{"chat" => %{"id" => chat_id}, "from" => %{"id" => user_id}} = msg, state) do
    text = msg["text"] || ""

    cond do
      String.starts_with?(text, "/start") ->
        handle_start(user_id, chat_id, msg, state)

      String.starts_with?(text, "/stop") ->
        handle_stop(user_id, chat_id, state)

      String.starts_with?(text, "/deregister") ->
        handle_stop(user_id, chat_id, state)

      String.starts_with?(text, "/pair") ->
        handle_pair(user_id, chat_id, state)

      Map.has_key?(state.pending, user_id) ->
        handle_pending(user_id, chat_id, text, msg, state)

      Map.has_key?(state.users, user_id) ->
        handle_user_message(user_id, msg, state)

      true ->
        Api.send_message(
          state.bot_token,
          chat_id,
          "Send /start to register as an agent on the Viche network."
        )

        state
    end
  end

  defp process_message(_msg, state), do: state

  defp handle_start(user_id, chat_id, msg, state) do
    username = get_in(msg, ["from", "username"])
    display_name = get_in(msg, ["from", "first_name"])

    case ensure_existing_registration(state, user_id) do
      {:ok, state, user} ->
        Api.send_message(
          state.bot_token,
          chat_id,
          "You're already registered as <b>#{escape_html(user.name)}</b> (#{user.agent_id}).\nSend /pair to connect private registries or /deregister to remove this Telegram agent.",
          parse_mode: "HTML"
        )

        state

      :not_registered ->
        Api.send_message(
          state.bot_token,
          chat_id,
          "Welcome to Viche on Telegram. What name would you like to register with?"
        )

        %{state | pending: Map.put(state.pending, user_id, :awaiting_name)}
        |> maybe_store_profile(user_id, username, display_name)
    end
  end

  defp handle_stop(user_id, chat_id, state) do
    case Map.get(state.users, user_id) do
      nil ->
        Api.send_message(state.bot_token, chat_id, "You're not registered.")
        state

      user ->
        Phoenix.PubSub.unsubscribe(Viche.PubSub, "agent:#{user.agent_id}")
        _ = Telegram.delete_agent_link(user.agent_id)
        _ = Agents.deregister(user.agent_id)

        Api.send_message(
          state.bot_token,
          chat_id,
          "Deregistered <b>#{escape_html(user.name)}</b> from Viche.",
          parse_mode: "HTML"
        )

        %{
          state
          | users: Map.delete(state.users, user_id),
            pending: Map.delete(state.pending, user_id)
        }
    end
  end

  defp handle_pair(user_id, chat_id, state) do
    case Map.get(state.users, user_id) do
      nil ->
        Api.send_message(state.bot_token, chat_id, "Register first with /start, then run /pair.")
        state

      user ->
        maybe_send_pairing_link(user, chat_id, state)
    end
  end

  defp handle_pending(user_id, chat_id, text, msg, state) do
    case state.pending[user_id] do
      :awaiting_name ->
        name = String.trim(text)

        if name == "" do
          Api.send_message(state.bot_token, chat_id, "Name cannot be empty. Please try again.")
          state
        else
          Api.send_message(
            state.bot_token,
            chat_id,
            "Got it, <b>#{escape_html(name)}</b>. What capabilities do you have? Send them as a comma-separated list.",
            parse_mode: "HTML"
          )

          %{state | pending: Map.put(state.pending, user_id, {:awaiting_capabilities, name})}
          |> maybe_store_profile(
            user_id,
            get_in(msg, ["from", "username"]),
            get_in(msg, ["from", "first_name"])
          )
        end

      {:awaiting_capabilities, name} ->
        capabilities =
          text
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if capabilities == [] do
          Api.send_message(state.bot_token, chat_id, "Please provide at least one capability.")
          state
        else
          complete_registration(user_id, chat_id, name, capabilities, msg, state)
        end
    end
  end

  defp complete_registration(user_id, chat_id, name, capabilities, msg, state) do
    attrs = %{
      capabilities: capabilities,
      connection_type: :websocket,
      name: name,
      description: "Telegram user #{name}"
    }

    case Agents.register_agent(attrs) do
      {:ok, agent} ->
        case Telegram.create_agent_link(%{
               agent_id: agent.id,
               bot_id: state.bot_id,
               telegram_user_id: user_id,
               chat_id: chat_id,
               telegram_username: get_in(msg, ["from", "username"]),
               telegram_name: get_in(msg, ["from", "first_name"]) || name
             }) do
          {:ok, _link} ->
            state = track_user(state, user_id, agent.id, name, capabilities, chat_id)

            Api.send_message(
              state.bot_token,
              chat_id,
              "<b>Registered.</b> Agent ID: <code>#{agent.id}</code>\nThis Telegram agent stays online until you send /deregister. Use /pair to claim it to your Viche account.",
              parse_mode: "HTML"
            )

            %{state | pending: Map.delete(state.pending, user_id)}

          {:error, reason} ->
            _ = Agents.deregister(agent.id)
            Api.send_message(state.bot_token, chat_id, "Registration failed: #{inspect(reason)}")
            %{state | pending: Map.delete(state.pending, user_id)}
        end

      {:error, reason} ->
        Api.send_message(state.bot_token, chat_id, "Registration failed: #{inspect(reason)}")
        %{state | pending: Map.delete(state.pending, user_id)}
    end
  end

  defp handle_user_message(user_id, msg, state) do
    user = state.users[user_id]
    text = msg["text"] || ""
    reply_to = get_in(msg, ["reply_to_message", "message_id"])

    if reply_to && Map.has_key?(state.message_map, reply_to) do
      route_reply(user, text, state.message_map[reply_to].from, state)
    else
      show_agent_picker(user, text, state)
    end
  end

  defp show_agent_picker(user, text, state) do
    case Agents.discover(%{capability: "*"}) do
      {:ok, agents} ->
        agents
        |> Enum.reject(&(&1.id == user.agent_id))
        |> maybe_show_agent_picker(user, text, state)

      {:error, _} ->
        Api.send_message(
          state.bot_token,
          user.chat_id,
          "Failed to discover agents. Please try again."
        )

        state
    end
  end

  defp ensure_callback_data_fits(buttons, text, user, state) do
    sample_data = "send|00000000-0000-0000-0000-000000000000|#{text}"

    if byte_size(sample_data) <= 64 do
      {buttons, state}
    else
      ref = "ref-#{:erlang.unique_integer([:positive])}"

      state =
        put_in(state, [:message_map, ref], %{
          from: user.agent_id,
          at: System.system_time(:millisecond),
          text: text
        })

      buttons =
        Enum.map(buttons, fn [%{text: label, callback_data: data}] ->
          agent_id = data |> String.split("|") |> Enum.at(1)
          [%{text: label, callback_data: "ref|#{agent_id}|#{ref}"}]
        end)

      {buttons, state}
    end
  end

  defp process_callback_query(
         %{"id" => cb_id, "from" => %{"id" => user_id}, "data" => data},
         state
       ) do
    _ = Api.answer_callback_query(state.bot_token, cb_id)

    case Map.get(state.users, user_id) do
      nil ->
        state

      user ->
        handle_callback_data(user, data, state)
    end
  end

  defp process_callback_query(_cb, state), do: state

  defp send_to_agent(user, agent_id, text, state) do
    case Agents.send_message(%{to: agent_id, from: user.agent_id, body: text, type: "task"}) do
      {:ok, _} ->
        Api.send_message(
          state.bot_token,
          user.chat_id,
          "Message sent to <code>#{escape_html(agent_id)}</code>.",
          parse_mode: "HTML"
        )

        state

      {:error, :agent_not_found} ->
        Api.send_message(
          state.bot_token,
          user.chat_id,
          "Agent not found — they may have gone offline."
        )

        state

      {:error, reason} ->
        Api.send_message(state.bot_token, user.chat_id, "Failed to send: #{inspect(reason)}")
        state
    end
  end

  defp forward_to_telegram(user, payload, state) do
    from_name = resolve_agent_name(payload.from)
    type_label = String.capitalize(payload.type || "message")

    card = """
    <b>From: #{escape_html(from_name)}</b>
    <i>Type: #{escape_html(type_label)}</i>

    #{escape_html(payload.body)}
    """

    case Api.send_message(state.bot_token, user.chat_id, card, parse_mode: "HTML") do
      {:ok, %{"message_id" => tg_msg_id}} ->
        entry = %{from: payload.from, at: System.system_time(:millisecond)}
        state = prune_message_map(state)
        put_in(state, [:message_map, tg_msg_id], entry)

      {:error, reason} ->
        Logger.warning(
          "Failed to forward message to Telegram user #{user.chat_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp restore_links(state) do
    Telegram.list_agent_links()
    |> Enum.filter(&(&1.bot_id == state.bot_id))
    |> Enum.reduce(state, fn link, acc ->
      case Agents.reactivate_agent(link.agent_id, connection_type: :websocket) do
        {:ok, agent} ->
          track_user(
            acc,
            link.telegram_user_id,
            agent.id,
            agent.name || link.telegram_name || "telegram-user",
            agent.capabilities,
            link.chat_id
          )

        {:error, :agent_not_found} ->
          acc
      end
    end)
  end

  defp track_user(state, telegram_user_id, agent_id, name, capabilities, chat_id) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{agent_id}")

    user_info = %{
      agent_id: agent_id,
      name: name,
      capabilities: capabilities,
      chat_id: chat_id,
      telegram_user_id: telegram_user_id
    }

    %{state | users: Map.put(state.users, telegram_user_id, user_info)}
  end

  defp ensure_existing_registration(state, telegram_user_id) do
    case Map.get(state.users, telegram_user_id) do
      nil ->
        maybe_restore_registration(state, telegram_user_id)

      user ->
        {:ok, state, user}
    end
  end

  defp maybe_store_profile(state, _user_id, _username, _display_name), do: state

  defp resolve_agent_name(agent_id) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [{_pid, meta}] -> meta.name || agent_id
      [] -> agent_id
    end
  end

  defp prune_message_map(state) do
    cutoff = System.system_time(:millisecond) - @message_map_ttl_ms

    pruned =
      state.message_map
      |> Enum.reject(fn
        {_key, %{at: at}} -> at < cutoff
        _ -> false
      end)
      |> Map.new()

    %{state | message_map: pruned}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp find_user_by_agent_id(state, agent_id) do
    Enum.find(state.users, fn {_telegram_user_id, user} -> user.agent_id == agent_id end)
  end

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_html(other), do: escape_html(to_string(other))

  defp maybe_send_pairing_link(user, chat_id, state) do
    if Telegram.pairing_enabled?() do
      send_pairing_link(user, chat_id, state)
    else
      Api.send_message(
        state.bot_token,
        chat_id,
        "Pairing is disabled on this Viche instance because account authentication is turned off."
      )

      state
    end
  end

  defp send_pairing_link(user, chat_id, state) do
    case Telegram.create_pairing_token(user.agent_id) do
      {:ok, raw_token} ->
        Api.send_message(
          state.bot_token,
          chat_id,
          "Open this link to claim your Telegram agent and join private registries:\n#{Telegram.pair_url(raw_token)}"
        )

        state

      {:error, _reason} ->
        Api.send_message(
          state.bot_token,
          chat_id,
          "Failed to create a pairing link. Please try again."
        )

        state
    end
  end

  defp route_reply(user, text, target_agent_id, state) do
    case Agents.send_message(%{
           to: target_agent_id,
           from: user.agent_id,
           body: text,
           type: "result"
         }) do
      {:ok, _} ->
        state

      {:error, :agent_not_found} ->
        Api.send_message(
          state.bot_token,
          user.chat_id,
          "The agent you replied to is no longer online."
        )

        state

      {:error, _} ->
        Api.send_message(state.bot_token, user.chat_id, "Failed to deliver your reply.")
        state
    end
  end

  defp maybe_show_agent_picker([], user, _text, state) do
    Api.send_message(state.bot_token, user.chat_id, "No other agents are currently online.")
    state
  end

  defp maybe_show_agent_picker(others, user, text, state) do
    buttons =
      Enum.map(others, fn agent ->
        label = agent.name || agent.id
        caps = Enum.join(agent.capabilities || [], ", ")
        [%{text: "#{label} (#{caps})", callback_data: "send|#{agent.id}|#{text}"}]
      end)

    {buttons, state} = ensure_callback_data_fits(buttons, text, user, state)

    Api.send_message(
      state.bot_token,
      user.chat_id,
      "Who should receive your message?",
      reply_markup: %{inline_keyboard: buttons}
    )

    state
  end

  defp handle_callback_data(user, data, state) do
    case String.split(data, "|", parts: 3) do
      ["send", agent_id, text] ->
        send_to_agent(user, agent_id, text, state)

      ["ref", agent_id, ref] ->
        deliver_referenced_callback(user, agent_id, ref, state)

      _ ->
        state
    end
  end

  defp deliver_referenced_callback(user, agent_id, ref, state) do
    case Map.get(state.message_map, ref) do
      %{text: text} ->
        state = %{state | message_map: Map.delete(state.message_map, ref)}
        send_to_agent(user, agent_id, text, state)

      nil ->
        Api.send_message(state.bot_token, user.chat_id, "Message expired. Please send it again.")
        state
    end
  end

  defp maybe_restore_registration(state, telegram_user_id) do
    case Telegram.get_agent_link_for_user(state.bot_id, telegram_user_id) do
      nil ->
        :not_registered

      link ->
        restore_registration_from_link(state, telegram_user_id, link)
    end
  end

  defp restore_registration_from_link(state, telegram_user_id, link) do
    case Agents.reactivate_agent(link.agent_id, connection_type: :websocket) do
      {:ok, agent} ->
        state =
          track_user(
            state,
            telegram_user_id,
            agent.id,
            agent.name || link.telegram_name || "telegram-user",
            agent.capabilities,
            link.chat_id
          )

        {:ok, state, state.users[telegram_user_id]}

      {:error, :agent_not_found} ->
        :not_registered
    end
  end
end
