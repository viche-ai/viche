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
    socket =
      assign(socket,
        token: token,
        status: :verifying,
        current_step: 0,
        completed_steps: MapSet.new(),
        status_text: "",
        step_labels: @step_labels
      )

    if connected?(socket) do
      case Auth.check_magic_link_token(token) do
        :ok ->
          Process.send_after(self(), {:activate_step, 1}, 600)
          {:ok, socket, layout: false}

        :error ->
          {:ok, assign(socket, status: :error), layout: false}
      end
    else
      {:ok, socket, layout: false}
    end
  end

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       token: nil,
       status: :error,
       current_step: 0,
       completed_steps: MapSet.new(),
       status_text: "",
       step_labels: @step_labels
     ), layout: false}
  end

  @impl true
  def handle_info({:activate_step, step}, socket) when step in 1..4 do
    status_messages = [
      "Authenticating magic link…",
      "Presenting credentials…",
      "Spinning up your workspace…",
      "Briefing the agent network…"
    ]

    Process.send_after(self(), {:complete_step, step}, 800)

    {:noreply,
     assign(socket,
       current_step: step,
       status_text: Enum.at(status_messages, step - 1)
     )}
  end

  def handle_info({:complete_step, step}, socket) when step in 1..4 do
    socket = update(socket, :completed_steps, &MapSet.put(&1, step))

    if step < 4 do
      Process.send_after(self(), {:activate_step, step + 1}, 400)
      {:noreply, socket}
    else
      Process.send_after(self(), :show_success, 500)
      {:noreply, socket}
    end
  end

  def handle_info(:show_success, socket) do
    Process.send_after(self(), :redirect_to_confirm, 2000)
    {:noreply, assign(socket, status: :success)}
  end

  def handle_info(:redirect_to_confirm, socket) do
    {:noreply, redirect(socket, to: ~p"/auth/confirm?token=#{socket.assigns.token}")}
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
