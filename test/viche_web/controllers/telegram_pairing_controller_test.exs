defmodule VicheWeb.TelegramPairingControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.Accounts
  alias Viche.Agents
  alias Viche.Registries
  alias Viche.Telegram

  setup do
    clear_agents()
    original = Application.get_env(:viche, :require_auth)
    Application.put_env(:viche, :require_auth, true)
    on_exit(fn -> Application.put_env(:viche, :require_auth, original) end)
    :ok
  end

  test "GET /telegram/pair redirects anonymous users to login", %{conn: conn} do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"]})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 1,
        telegram_user_id: 2,
        chat_id: 3
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)

    conn = get(conn, ~p"/telegram/pair?token=#{raw_token}")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :pending_pairing_token) == raw_token
  end

  test "GET /telegram/pair renders registry choices for logged-in user", %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "pair@example.com", username: "pair_user"})

    {:ok, registry} =
      Registries.create_registry(user.id, %{name: "Owned", slug: "owned-pair", is_private: true})

    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"]})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 1,
        telegram_user_id: 2,
        chat_id: 3
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/telegram/pair?token=#{raw_token}")

    assert html_response(conn, 200) =~ registry.name
    assert html_response(conn, 200) =~ "telegram-pairing-form"
  end

  test "POST /telegram/pair claims the agent and joins selected registries", %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{email: "postpair@example.com", username: "post_pair_user"})

    {:ok, registry} =
      Registries.create_registry(user.id, %{
        name: "Owned",
        slug: "owned-post-pair",
        is_private: true
      })

    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"]})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 1,
        telegram_user_id: 2,
        chat_id: 3
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> post(~p"/telegram/pair", %{
        "pairing" => %{"token" => raw_token, "registry_ids" => [registry.id]}
      })

    assert redirected_to(conn) == ~p"/dashboard"
    assert Agents.get_agent_record(agent.id).user_id == user.id
    assert {:ok, registries} = Agents.list_agent_registries_for(agent.id)
    refute "global" in registries
    assert registry.id in registries
  end

  test "GET /telegram/pair is disabled when auth is off", %{conn: conn} do
    original = Application.get_env(:viche, :require_auth)
    Application.put_env(:viche, :require_auth, false)

    on_exit(fn ->
      Application.put_env(:viche, :require_auth, original)
    end)

    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"]})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 1,
        telegram_user_id: 2,
        chat_id: 3
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)

    conn = get(conn, ~p"/telegram/pair?token=#{raw_token}")

    assert redirected_to(conn) == ~p"/dashboard"
  end

  defp clear_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)
  end
end
