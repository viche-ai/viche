defmodule Viche.Telegram.BridgeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Req.Test, as: ReqTest
  alias Viche.Telegram
  alias Viche.Telegram.Bridge

  @bot_token "test_bot_token"
  @bot_id 111
  @telegram_user_id 222
  @chat_id 333

  setup do
    original_auth = Application.get_env(:viche, :require_auth)
    Application.put_env(:viche, :require_auth, true)

    on_exit(fn ->
      Application.put_env(:viche, :require_auth, original_auth)
    end)

    owner = Sandbox.start_owner!(Viche.Repo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(owner)
    end)

    clear_agents()

    case GenServer.whereis(Bridge) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    ReqTest.set_req_test_to_shared(self())
    stub_updates([])
    :ok
  end

  test "registers a telegram user and returns a pairing link" do
    {:ok, pid} = Bridge.start_link(bot_token: @bot_token)

    stub_updates([make_update(1, make_message("/start"))])
    send(pid, :poll)
    assert_receive {:tg_sent, %{"text" => text}}, 1_000
    assert text =~ "What name"

    stub_updates([make_update(2, make_message("Bridge User"))])
    send(pid, :poll)
    assert_receive {:tg_sent, %{"text" => text}}, 1_000
    assert text =~ "capabilities"

    stub_updates([make_update(3, make_message("coding, review"))])
    send(pid, :poll)
    assert_receive {:tg_sent, %{"text" => text}}, 1_000
    assert text =~ "Registered"

    assert link = Telegram.get_agent_link_for_user(@bot_id, @telegram_user_id)

    assert {:ok, agent} =
             Viche.Agents.reactivate_agent(link.agent_id, connection_type: :websocket)

    assert agent.connection_type == :websocket

    stub_updates([make_update(4, make_message("/pair"))])
    send(pid, :poll)
    assert_receive {:tg_sent, %{"text" => text}}, 1_000
    assert text =~ "/telegram/pair?token="
  end

  test "/deregister removes the telegram agent" do
    {:ok, pid} = Bridge.start_link(bot_token: @bot_token)

    stub_updates([
      make_update(1, make_message("/start")),
      make_update(2, make_message("Bridge User")),
      make_update(3, make_message("coding"))
    ])

    send(pid, :poll)
    assert_receive {:tg_sent, _}, 1_000
    assert_receive {:tg_sent, _}, 1_000
    assert_receive {:tg_sent, %{"text" => registered_text}}, 1_000
    assert registered_text =~ "Registered"

    assert link = Telegram.get_agent_link_for_user(@bot_id, @telegram_user_id)

    stub_updates([make_update(4, make_message("/deregister"))])
    send(pid, :poll)
    assert_receive {:tg_sent, %{"text" => deregister_text}}, 1_000
    assert deregister_text =~ "Deregistered"
    assert Telegram.get_agent_link(link.agent_id) == nil
  end

  test "/pair is disabled when auth is off" do
    original_auth = Application.get_env(:viche, :require_auth)
    Application.put_env(:viche, :require_auth, false)

    on_exit(fn ->
      Application.put_env(:viche, :require_auth, original_auth)
    end)

    {:ok, pid} = Bridge.start_link(bot_token: @bot_token)

    stub_updates([
      make_update(1, make_message("/start")),
      make_update(2, make_message("Bridge User")),
      make_update(3, make_message("coding")),
      make_update(4, make_message("/pair"))
    ])

    send(pid, :poll)
    assert_receive {:tg_sent, _}, 1_000
    assert_receive {:tg_sent, _}, 1_000
    assert_receive {:tg_sent, _}, 1_000
    assert_receive {:tg_sent, %{"text" => text}}, 1_000
    assert text =~ "Pairing is disabled"
  end

  defp stub_updates(updates) do
    test_pid = self()

    ReqTest.stub(:telegram_api, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/getMe") ->
          ReqTest.json(conn, %{
            "ok" => true,
            "result" => %{"id" => @bot_id, "username" => "test_bot", "is_bot" => true}
          })

        String.ends_with?(conn.request_path, "/getUpdates") ->
          ReqTest.json(conn, %{"ok" => true, "result" => updates})

        String.ends_with?(conn.request_path, "/sendMessage") ->
          {:ok, body, _conn} = Plug.Conn.read_body(conn)
          parsed = Jason.decode!(body)
          send(test_pid, {:tg_sent, parsed})
          ReqTest.json(conn, %{"ok" => true, "result" => %{"message_id" => 999}})

        true ->
          ReqTest.json(conn, %{"ok" => true, "result" => true})
      end
    end)
  end

  defp make_update(update_id, message), do: %{"update_id" => update_id, "message" => message}

  defp make_message(text) do
    %{
      "message_id" => :rand.uniform(100_000),
      "text" => text,
      "from" => %{
        "id" => @telegram_user_id,
        "first_name" => "Bridge",
        "username" => "bridge_user"
      },
      "chat" => %{"id" => @chat_id}
    }
  end

  defp clear_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)
  end
end
