defmodule VicheWeb.AgentSocketAuthTest do
  @moduledoc """
  Tests for WebSocket authentication in AgentSocket (Issue #20).

  Covers:
  - Socket connects successfully for agent owner with valid token
  - Socket rejects connection for non-owner (different user's token)
  - Socket rejects connection when no token and agent is owned (REQUIRE_AUTH off but agent is owned)
  - Unclaimed agents allow tokenless connections
  """

  use VicheWeb.ChannelCase

  alias Viche.{Accounts, Agents, Auth}

  defp create_user_with_token do
    {:ok, user} = Accounts.create_user(%{email: "ws-test-#{System.unique_integer()}@example.com"})
    {:ok, token_string, _} = Auth.create_api_token(user.id)
    {user, token_string}
  end

  defp clear_all_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    Viche.AgentRegistry
    |> Supervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} -> _ = :sys.get_state(pid) end)

    :ok
  end

  setup do
    clear_all_agents()
    :ok
  end

  describe "AgentSocket.connect/3 — token authentication" do
    test "owner with valid token can connect" do
      {user, token} = create_user_with_token()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user.id})

      assert {:ok, socket} =
               connect(VicheWeb.AgentSocket, %{
                 "agent_id" => agent.id,
                 "token" => token
               })

      assert socket.assigns.agent_id == agent.id
    end

    test "non-owner (different user's token) is rejected" do
      {user1, _token1} = create_user_with_token()
      {_user2, token2} = create_user_with_token()

      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user1.id})

      assert :error =
               connect(VicheWeb.AgentSocket, %{
                 "agent_id" => agent.id,
                 "token" => token2
               })
    end

    test "invalid token is rejected" do
      {user, _} = create_user_with_token()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user.id})

      assert :error =
               connect(VicheWeb.AgentSocket, %{
                 "agent_id" => agent.id,
                 "token" => "invalid-token-abc123"
               })
    end

    test "unclaimed agent allows tokenless connection" do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"]})

      assert {:ok, socket} =
               connect(VicheWeb.AgentSocket, %{"agent_id" => agent.id})

      assert socket.assigns.agent_id == agent.id
    end

    test "owned agent without token is rejected (no REQUIRE_AUTH doesn't help here)" do
      {user, _} = create_user_with_token()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user.id})

      # No token provided — owned agents require a token
      assert :error =
               connect(VicheWeb.AgentSocket, %{"agent_id" => agent.id})
    end

    test "connection without agent_id is rejected" do
      assert :error = connect(VicheWeb.AgentSocket, %{})
    end

    test "connection with empty agent_id is rejected" do
      assert :error = connect(VicheWeb.AgentSocket, %{"agent_id" => ""})
    end
  end
end
