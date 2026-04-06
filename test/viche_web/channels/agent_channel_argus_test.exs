defmodule VicheWeb.AgentChannelArgusTest do
  use VicheWeb.ChannelCase, async: true
  alias VicheWeb.AgentSocket

  setup do
    {:ok, agent} = Viche.Agents.register_agent(%{capabilities: ["test"], name: "Test Agent"})
    agent_id = agent.id

    {:ok, _, socket} =
      socket(AgentSocket, "agent:#{agent_id}", %{agent_id: agent_id})
      |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

    %{socket: socket}
  end

  test "Argus: API boundary — discover crashes if capability is not a string", %{socket: socket} do
    # When capability is an integer, the backend returns {:error, :query_required}
    # which causes a MatchError because handle_in asserts {:ok, agents} = ...
    # This test FAILS if the bug exists (channel crashes or times out)
    # This test PASSES if the bug is fixed (channel replies with an error gracefully)
    ref = push(socket, "discover", %{"capability" => 123})

    assert_reply ref, :error, %{error: _, message: _}, 500
  end
end
