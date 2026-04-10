defmodule VicheWeb.VerifyLive do
  use VicheWeb, :live_view

  alias Viche.Auth

  @step_labels [
    "Verifying magic link",
    "Exchanging token for credentials",
    "Spinning up your workspace",
    "Connecting to the agent network"
  ]

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "metrics:messages")
      :timer.send_interval(10_000, :refresh_agents)
    end

    agents_online =
      Viche.Agents.list_agents_with_status()
      |> Enum.count(fn agent -> agent.status == :online end)

    socket =
      assign(socket,
        token: token,
        status: :verifying,
        current_step: 0,
        completed_steps: MapSet.new(),
        status_text: "",
        step_labels: @step_labels,
        agents_online: agents_online,
        messages_today: Viche.MessageCounter.get()
      )

    if connected?(socket) do
      case Auth.check_magic_link_token(token) do
        :ok ->
          {:ok, assign(socket, status: :success), layout: false}

        :error ->
          {:ok, assign(socket, status: :error), layout: false}
      end
    else
      {:ok, socket, layout: false}
    end
  end

  def mount(_params, _session, socket) do
    agents_online =
      Viche.Agents.list_agents_with_status()
      |> Enum.count(fn agent -> agent.status == :online end)

    {:ok,
     assign(socket,
       token: nil,
       status: :error,
       current_step: 0,
       completed_steps: MapSet.new(),
       status_text: "",
       step_labels: @step_labels,
       agents_online: agents_online,
       messages_today: Viche.MessageCounter.get()
     ), layout: false}
  end

  @impl true
  def handle_info({:messages_today, count}, socket) do
    {:noreply, assign(socket, messages_today: count)}
  end

  def handle_info(:refresh_agents, socket) do
    agents_online =
      Viche.Agents.list_agents_with_status()
      |> Enum.count(fn agent -> agent.status == :online end)

    {:noreply, assign(socket, agents_online: agents_online)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helpers used by the template

  def step_class(step, current_step, completed_steps) do
    cond do
      MapSet.member?(completed_steps, step) -> "done"
      step == current_step -> "active"
      true -> ""
    end
  end

  def dot_class(step, current_step, completed_steps) do
    cond do
      MapSet.member?(completed_steps, step) -> "vfy-dot done"
      step == current_step -> "vfy-dot active"
      true -> "vfy-dot"
    end
  end

  def step_icon(step, completed_steps) do
    if MapSet.member?(completed_steps, step), do: "✓", else: "↻"
  end
end
