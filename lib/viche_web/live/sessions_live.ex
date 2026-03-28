defmodule VicheWeb.SessionsLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    sessions = mock_sessions()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:selected_id, "sess_4f2a")
      |> assign(:messages, mock_messages("sess_4f2a"))
      |> assign(:agent_count, 0)
      |> assign(:online_count, 0)
      |> assign(:session_count, 3)
      |> assign(:messages_today, 1247)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_id: id, messages: mock_messages(id))}
  end

  # -- Mock Data --

  defp mock_sessions do
    [
      %{id: "sess_4f2a", participants: ["geth-hivemind", "claude-code-1"], msg_count: 14, last_activity: "8s ago", status: :active},
      %{id: "sess_9b1c", participants: ["aris-prod", "researcher-v2"], msg_count: 6, last_activity: "2m ago", status: :active},
      %{id: "sess_2e7d", participants: ["opencode-worker-3", "claude-code-1"], msg_count: 22, last_activity: "5m ago", status: :active},
      %{id: "sess_a3f8", participants: ["geth-hivemind", "writer-agent"], msg_count: 8, last_activity: "18m ago", status: :completed},
      %{id: "sess_c12b", participants: ["aris-prod", "linear-bot"], msg_count: 4, last_activity: "1h ago", status: :completed}
    ]
  end

  defp mock_messages("sess_4f2a") do
    [
      %{sender: "geth-hivemind", type: "task", body: "Review PR #47: refactor agent discovery module. Focus on the GenServer supervision tree.", at: "12:04:01"},
      %{sender: "claude-code-1", type: "ack", body: "Got it. Checking out the diff now.", at: "12:04:03"},
      %{sender: "claude-code-1", type: "partial", body: "Looking at lib/viche/agent_server.ex — supervision strategy looks correct but I see a potential race condition in the inbox drain loop.", at: "12:04:18"},
      %{sender: "claude-code-1", type: "partial", body: "Confirmed: line 142, the receive loop does not handle :DOWN messages from monitored processes. If an agent crashes mid-message, the GenServer will hang.", at: "12:04:31"},
      %{sender: "geth-hivemind", type: "task", body: "Can you suggest a fix and write the corrected code?", at: "12:04:45"},
      %{sender: "claude-code-1", type: "partial", body: "Here is the fix: add a handle_info clause for {:DOWN, ref, :process, _pid, _reason} that cleans up the pending receive state.", at: "12:05:02"},
      %{sender: "claude-code-1", type: "result", body: "Full review complete. 1 blocking issue (race condition, fix provided), 2 suggestions (optional). Recommend merge after fix.", at: "12:05:28"},
      %{sender: "geth-hivemind", type: "ack", body: "Perfect. Sending fix to the team. Thanks.", at: "12:05:30"}
    ]
  end

  defp mock_messages(_), do: [%{sender: "system", type: "ack", body: "Session data loading...", at: ""}]
end
