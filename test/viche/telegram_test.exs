defmodule Viche.TelegramTest do
  use Viche.DataCase, async: false

  alias Viche.Accounts
  alias Viche.Agents
  alias Viche.Registries
  alias Viche.Telegram

  setup do
    clear_agents()

    original_auth = Application.get_env(:viche, :require_auth)
    Application.put_env(:viche, :require_auth, true)

    on_exit(fn ->
      Application.put_env(:viche, :require_auth, original_auth)
    end)

    :ok
  end

  test "creates and fetches a telegram agent link" do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"], name: "tg-user"})

    assert {:ok, link} =
             Telegram.create_agent_link(%{
               agent_id: agent.id,
               bot_id: 1,
               telegram_user_id: 2,
               chat_id: 3,
               telegram_username: "tg_user",
               telegram_name: "TG User"
             })

    assert Telegram.get_agent_link(agent.id).id == link.id
    assert Telegram.get_agent_link_for_user(1, 2).agent_id == agent.id
  end

  test "pair_agent/3 claims the agent and joins selected registries" do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"], name: "tg-user"})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 11,
        telegram_user_id: 22,
        chat_id: 33
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)
    {:ok, user} = Accounts.create_user(%{email: "owner@example.com", username: "owner_user"})

    {:ok, member_owner} =
      Accounts.create_user(%{email: "member-owner@example.com", username: "member_owner"})

    {:ok, owned_registry} =
      Registries.create_registry(user.id, %{
        name: "Owned",
        slug: "owned-registry",
        is_private: true
      })

    {:ok, member_registry} =
      Registries.create_registry(member_owner.id, %{
        name: "Member",
        slug: "member-registry",
        is_private: true
      })

    {:ok, _member} = Registries.add_member(member_registry.id, user.id)

    assert {:ok, %{agent_id: paired_agent_id, joined_registries: joined}} =
             Telegram.pair_agent(raw_token, user.id, [owned_registry.id, member_registry.id])

    assert paired_agent_id == agent.id
    assert Enum.sort(joined) == Enum.sort([owned_registry.id, member_registry.id])

    assert Agents.get_agent_record(agent.id).user_id == user.id
    assert {:ok, registries} = Agents.list_agent_registries_for(agent.id)
    refute "global" in registries
    assert owned_registry.id in registries
    assert member_registry.id in registries
  end

  test "pair_agent/3 works after the in-memory agent process is gone" do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"], name: "tg-user"})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 11,
        telegram_user_id: 22,
        chat_id: 33
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)
    {:ok, user} = Accounts.create_user(%{email: "reclaim@example.com", username: "reclaim_user"})

    [{_id, pid, _type, _modules}] = DynamicSupervisor.which_children(Viche.AgentSupervisor)
    :ok = DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)

    assert {:ok, %{agent_id: paired_agent_id, joined_registries: []}} =
             Telegram.pair_agent(raw_token, user.id, [])

    assert paired_agent_id == agent.id
    assert Agents.get_agent_record(agent.id).user_id == user.id
    assert {:ok, reactivated} = Agents.reactivate_agent(agent.id, connection_type: :websocket)
    assert reactivated.connection_type == :websocket
  end

  test "pair_agent/3 rejects registries the user cannot access" do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"], name: "tg-user"})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 11,
        telegram_user_id: 22,
        chat_id: 33
      })

    {:ok, raw_token} = Telegram.create_pairing_token(agent.id)
    {:ok, user} = Accounts.create_user(%{email: "owner2@example.com", username: "owner_two"})

    {:ok, outsider} =
      Accounts.create_user(%{email: "outsider@example.com", username: "outsider_user"})

    {:ok, outsider_registry} =
      Registries.create_registry(outsider.id, %{
        name: "Nope",
        slug: "nope-registry",
        is_private: true
      })

    assert {:error, :not_allowed_registry} =
             Telegram.pair_agent(raw_token, user.id, [outsider_registry.id])

    assert Agents.get_agent_record(agent.id).user_id == nil
  end

  test "create_pairing_token/1 leaves only the newest token active" do
    {:ok, agent} = Agents.register_agent(%{capabilities: ["telegram"], name: "tg-user"})

    {:ok, _link} =
      Telegram.create_agent_link(%{
        agent_id: agent.id,
        bot_id: 11,
        telegram_user_id: 22,
        chat_id: 33
      })

    {:ok, first_token} = Telegram.create_pairing_token(agent.id)
    {:ok, second_token} = Telegram.create_pairing_token(agent.id)

    assert {:error, :invalid_token} = Telegram.get_valid_pairing(first_token)
    assert {:ok, _pairing, _link} = Telegram.get_valid_pairing(second_token)
  end

  defp clear_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)
  end
end
