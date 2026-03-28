# Mockup → Phoenix LiveView: Conversion Guide

**Stack:** Phoenix 1.8 · LiveView 1.1 · Tailwind 4 · daisyUI · Heroicons  
**Purpose:** Repeatable process for turning `mockups/*.html` into live, server-rendered pages  
**Last updated:** 2026-03-28

---

## Overview

Each HTML mockup becomes a LiveView module. The pattern is always:

```
mockups/foo.html
  → lib/viche_web/live/foo_live.ex            (LiveView — mount, handle_event, handle_info)
  → lib/viche_web/live/foo_live.html.heex     (HEEx template)
  → lib/viche_web/components/mc_components.ex (shared sub-components)
  → router.ex: live "/foo", FooLive
```

CSS lives in Tailwind utilities. Shared Everforest tokens go in `assets/css/app.css` under `@theme`.

---

## Step 0 — One-time: Everforest CSS tokens

Add to `assets/css/app.css` after the `@import "tailwindcss"` line:

```css
@theme {
  /* Everforest Dark */
  --color-ef-bg0:    #2D353B;
  --color-ef-bg1:    #343F44;
  --color-ef-bg2:    #3D484D;
  --color-ef-bg3:    #475258;
  --color-ef-bg4:    #4F585E;
  --color-ef-fg:     #D3C6AA;
  --color-ef-dim:    #859289;
  --color-ef-green:  #A7C080;
  --color-ef-aqua:   #83C092;
  --color-ef-blue:   #7FBBB3;
  --color-ef-yellow: #DBBC7F;
  --color-ef-purple: #D699B6;
  --color-ef-orange: #E69875;
  --color-ef-red:    #E67E80;

  /* Everforest Light */
  --color-efl-bg0:   #FDF6E3;
  --color-efl-bg1:   #F4F0D9;
  --color-efl-fg:    #5C6A72;
  --color-efl-dim:   #829181;
  --color-efl-green: #8DA101;
  --color-efl-aqua:  #35A77C;
  --color-efl-blue:  #3A94C5;
}

/* Semantic aliases that flip with data-theme */
:root, [data-theme="dark"] {
  --bg:     var(--color-ef-bg0);
  --bg-1:   var(--color-ef-bg1);
  --bg-2:   var(--color-ef-bg2);
  --fg:     var(--color-ef-fg);
  --fg-dim: var(--color-ef-dim);
  --accent: var(--color-ef-green);
  --border: rgba(255,255,255,0.07);
}

[data-theme="light"] {
  --bg:     var(--color-efl-bg0);
  --bg-1:   var(--color-efl-bg1);
  --bg-2:   var(--color-efl-bg1);
  --fg:     var(--color-efl-fg);
  --fg-dim: var(--color-efl-dim);
  --accent: var(--color-efl-green);
  --border: rgba(0,0,0,0.09);
}
```

Tailwind 4 picks up `--color-*` automatically. Use as `bg-ef-bg1`, `text-ef-green`, `border-ef-blue/40` etc.

---

## Step 1 — Register the route

`lib/viche_web/router.ex`, inside the browser scope:

```elixir
scope "/", VicheWeb do
  pipe_through :browser

  get "/", PageController, :home   # existing

  live "/dashboard",      DashboardLive
  live "/network",        NetworkLive
  live "/agents",         AgentsLive
  live "/agents/:id",     AgentDetailLive
  live "/sessions",       SessionsLive
  live "/sessions/:id",   SessionDetailLive
  live "/demo",           DemoLive
  live "/join/:hash",     JoinLive
  live "/settings",       SettingsLive
end
```

---

## Step 2 — Create the LiveView module

`lib/viche_web/live/dashboard_live.ex`:

```elixir
defmodule VicheWeb.DashboardLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:events")
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:presence")
      :timer.send_interval(5_000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:agents, Viche.Agents.list_agents())
     |> assign(:sessions_count, 0)
     |> assign(:messages_today, 0)
     |> assign(:feed, [])}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :agents, Viche.Agents.list_agents())}
  end

  def handle_info({:agent_event, event}, socket) do
    feed = [event | Enum.take(socket.assigns.feed, 9)]
    {:noreply, assign(socket, :feed, feed)}
  end
end
```

**Key callbacks:**

| Callback | Purpose |
|---|---|
| `mount/3` | Initial assigns + PubSub subscribe |
| `handle_event/3` | User interactions (clicks, form inputs) |
| `handle_info/2` | PubSub messages + timer ticks |
| `handle_params/3` | URL param changes (filters, IDs) |

---

## Step 3 — HTML → HEEx translation

### Syntax cheat sheet

| HTML (mockup) | HEEx | Notes |
|---|---|---|
| `{{ variable }}` | `{@variable}` | Elixir assigns |
| `onclick="fn()"` | `phx-click="event_name"` | Server event |
| `<div id="x">` | `<div id="x">` | Same |
| JS `if` | `<%= if @cond do %> ... <% end %>` or `:if={@cond}` attr | |
| JS `for` loop | `<%= for item <- @list do %> ... <% end %>` | |
| `setInterval` | `:timer.send_interval` + `handle_info` | Server-driven |
| JS fetch | `handle_event` + assign | No AJAX needed |
| dynamic `class` | `class={["base", @cond && "extra"]}` | List of classes |

### Stat card example

Mockup:
```html
<div class="stat-card" onclick="...">
  <div class="stat-label">Total Agents</div>
  <div class="stat-value">24</div>
</div>
```

HEEx:
```heex
<div class="bg-ef-bg1 border border-[var(--border)] rounded-xl p-4 cursor-pointer
            hover:border-ef-green/40 transition-colors"
     phx-click="navigate_agents">
  <div class="text-[10.5px] font-semibold uppercase tracking-wide text-ef-dim mb-2">
    Total Agents
  </div>
  <div class="text-4xl font-bold tracking-tight tabular-nums">{@agent_count}</div>
</div>
```

### Agent list loop

```heex
<%= for agent <- @agents do %>
  <div class="grid grid-cols-[28px_1fr_90px_52px_80px] items-center gap-2.5 px-4 py-2.5
              border-b border-[var(--border)] cursor-pointer hover:bg-[var(--hover)]"
       phx-click="select_agent"
       phx-value-id={agent.id}>
    <.agent_avatar name={agent.name} color={agent.color} />
    <div>
      <div class="text-sm font-medium">{agent.name}</div>
      <div class="flex gap-1 mt-0.5">
        <%= for cap <- agent.capabilities do %>
          <.cap_tag name={cap} />
        <% end %>
      </div>
    </div>
    <.status_pill status={agent.status} />
    <div class="text-xs font-mono text-ef-dim text-right">{agent.queue_depth}</div>
    <div class="text-xs text-ef-dim">{agent.last_seen}</div>
  </div>
<% end %>
```

---

## Step 4 — Extract shared components

`lib/viche_web/components/mc_components.ex`:

```elixir
defmodule VicheWeb.MCComponents do
  use Phoenix.Component

  attr :status, :string, required: true
  def status_pill(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1 text-[10px] font-semibold
                   px-2 py-0.5 rounded-full before:content-[''] before:w-1.5
                   before:h-1.5 before:rounded-full before:bg-current",
                  status_classes(@status)]}>
      {@status}
    </span>
    """
  end

  defp status_classes("idle"),    do: "bg-ef-green/15 text-ef-green"
  defp status_classes("busy"),    do: "bg-ef-yellow/15 text-ef-yellow"
  defp status_classes("offline"), do: "bg-ef-dim/15 text-ef-dim"
  defp status_classes(_),         do: "bg-ef-dim/15 text-ef-dim"

  attr :name, :string, required: true
  def cap_tag(assigns) do
    ~H"""
    <span class={["text-[9.5px] font-mono px-1.5 py-0.5 rounded", cap_color(@name)]}>
      {@name}
    </span>
    """
  end
  defp cap_color("coding"),   do: "bg-ef-blue/15 text-ef-blue"
  defp cap_color("testing"),  do: "bg-ef-green/15 text-ef-green"
  defp cap_color("security"), do: "bg-ef-red/15 text-ef-red"
  defp cap_color(_),          do: "bg-ef-bg3 text-ef-dim"

  def live_dot(assigns) do
    ~H"""
    <span class="w-1.5 h-1.5 rounded-full bg-ef-green inline-block
                 animate-[pulse_2s_ease-in-out_infinite]" />
    """
  end

  attr :name, :string, required: true
  attr :color, :string, default: "green"
  def agent_avatar(assigns) do
    ~H"""
    <div class={["w-7 h-7 rounded-lg flex items-center justify-content-center
                  text-xs font-bold flex-shrink-0", avatar_bg(@color)]}>
      {String.upcase(String.first(@name))}
    </div>
    """
  end
  defp avatar_bg("blue"),   do: "bg-ef-blue/20 text-ef-blue"
  defp avatar_bg("purple"), do: "bg-ef-purple/20 text-ef-purple"
  defp avatar_bg("yellow"), do: "bg-ef-yellow/20 text-ef-yellow"
  defp avatar_bg(_),        do: "bg-ef-green/20 text-ef-green"
end
```

Import in `lib/viche_web.ex` inside `html_helpers/0`:

```elixir
defp html_helpers do
  quote do
    # ...existing...
    import VicheWeb.MCComponents
  end
end
```

---

## Step 5 — Shared layout (sidebar + topbar + status bar)

Create `lib/viche_web/components/layouts/mission_control.html.heex` and a function in `layouts.ex`:

```elixir
# lib/viche_web/components/layouts.ex
slot :inner_block, required: true
attr :active_nav, :atom, default: nil
attr :page_title, :string, default: "Viche"
attr :breadcrumb, :string, default: ""
attr :agent_count, :integer, default: 0
attr :online_count, :integer, default: 0
attr :session_count, :integer, default: 0
attr :messages_today, :integer, default: 0

def mission_control(assigns) do
  ~H"""
  <div class="flex h-screen overflow-hidden" style="background:var(--bg);color:var(--fg)">
    <aside class="w-[216px] min-w-[216px] flex flex-col border-r"
           style="background:var(--bg-1);border-color:var(--border)">
      <!-- logo, nav, footer... -->
    </aside>
    <main class="flex-1 flex flex-col overflow-hidden">
      <!-- topbar -->
      <div class="h-[50px] flex items-center px-6 gap-2 border-b flex-shrink-0"
           style="border-color:var(--border)">
        <span class="text-sm font-semibold">{@page_title}</span>
        <span class="text-xs" style="color:var(--fg-dim)">{@breadcrumb}</span>
        <div class="ml-auto flex items-center gap-2">
          <div class="flex items-center gap-1.5 text-xs" style="color:var(--fg-dim)">
            <.live_dot /> Live
          </div>
        </div>
      </div>
      <!-- page content -->
      {render_slot(@inner_block)}
      <!-- status bar -->
      <div class="h-6 flex items-center px-4 gap-4 border-t text-[10px] font-mono flex-shrink-0"
           style="background:var(--bg-1);border-color:var(--border);color:var(--fg-dim)">
        <.live_dot /> ws://viche.ai/socket
        <span>|</span> registry: public
        <span>|</span> {@agent_count} agents · {@online_count} online
        <span>|</span> {@messages_today} messages today
      </div>
    </main>
  </div>
  """
end
```

Use in every LiveView render:

```heex
<Layouts.mission_control active_nav={:dashboard} page_title="Dashboard" 
    breadcrumb="/ overview" agent_count={@agent_count} ...>
  <!-- page body here -->
</Layouts.mission_control>
```

---

## Step 6 — Real-time data via PubSub

### Broadcast from AgentServer / AgentChannel

```elixir
# When an agent sends a message:
Phoenix.PubSub.broadcast(Viche.PubSub, "agent:events", {:agent_event, %{
  type: :task, from: sender_id, to: receiver_id, body: body, at: DateTime.utc_now()
}})

# When presence changes:
Phoenix.PubSub.broadcast(Viche.PubSub, "agent:presence", {:presence_update, %{
  agent_id: id, status: :idle | :busy | :offline, queue_depth: n
}})
```

### Subscribe in LiveView

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:events")
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:presence")
  end
  ...
end

def handle_info({:agent_event, event}, socket) do
  feed = [event | Enum.take(socket.assigns.feed, 9)]
  {:noreply, assign(socket, :feed, feed)}
end

def handle_info({:presence_update, %{agent_id: id, status: status}}, socket) do
  agents = Enum.map(socket.assigns.agents, fn
    a when a.id == id -> %{a | status: status}
    a -> a
  end)
  {:noreply, assign(socket, :agents, agents)}
end
```

---

## Step 7 — D3 network graph (JS hook)

The force-directed graph must stay as a JS hook — LiveView does not replace D3.

```javascript
// assets/js/hooks/network_graph.js
export const NetworkGraph = {
  mounted() {
    const agents = JSON.parse(this.el.dataset.agents)
    const links  = JSON.parse(this.el.dataset.links)
    this.initD3(agents, links)

    // Server pushes pulse events
    this.handleEvent("graph_pulse", ({ from, to, color }) => {
      this.animatePulse(from, to, color)
    })

    this.handleEvent("graph_update", ({ agents, links }) => {
      this.updateNodes(agents, links)
    })
  },

  initD3(agents, links) {
    // Exact D3 force simulation from network.html mockup
    // (copy the D3 code block verbatim, replacing SVG ref)
  }
}
```

```javascript
// assets/js/app.js
import { NetworkGraph } from "./hooks/network_graph"
let Hooks = { NetworkGraph }
```

In template:
```heex
<div id="network-graph"
     phx-hook="NetworkGraph"
     data-agents={Jason.encode!(@agents)}
     data-links={Jason.encode!(@links)}
     class="flex-1 w-full h-full" />
```

Server pushes events:
```elixir
def handle_info({:agent_event, %{from: from, to: to} = event}, socket) do
  color = agent_color(from, socket.assigns.agents)
  socket = push_event(socket, "graph_pulse", %{from: from, to: to, color: color})
  {:noreply, update_feed(socket, event)}
end
```

---

## Step 8 — Handle user events

```heex
<!-- Filter chip -->
<button phx-click="filter" phx-value-status="idle"
        class={["btn-sm", @filter == "idle" && "ring-1 ring-ef-green"]}>
  Idle
</button>

<!-- Search (live, debounced) -->
<input phx-change="search" phx-debounce="200" name="query"
       value={@query} placeholder="Search agents..." />

<!-- Row click → navigate -->
<div phx-click="open_agent" phx-value-id={agent.id}>...</div>
```

```elixir
def handle_event("filter", %{"status" => s}, socket) do
  {:noreply, assign(socket, filter: s, agents: filter_agents(socket.assigns.all_agents, s))}
end

def handle_event("search", %{"query" => q}, socket) do
  {:noreply, assign(socket, query: q, agents: search_agents(socket.assigns.all_agents, q))}
end

def handle_event("open_agent", %{"id" => id}, socket) do
  {:noreply, push_navigate(socket, to: "/agents/#{id}")}
end
```

---

## Page-by-page notes

| Page | LiveView | Key assigns | PubSub topics | JS hooks |
|---|---|---|---|---|
| `/dashboard` | `DashboardLive` | `@agents`, `@feed`, `@messages_today` | `agent:events`, `agent:presence` | — |
| `/network` | `NetworkLive` | `@agents`, `@links`, `@feed` | `agent:events`, `agent:presence` | `NetworkGraph` |
| `/agents` | `AgentsLive` | `@agents`, `@filter`, `@query` | `agent:presence` | — |
| `/agents/:id` | `AgentDetailLive` | `@agent`, `@response`, `@dispatch_history` | `agent:#{id}` | `TaskResponse` |
| `/sessions` | `SessionsLive` | `@sessions`, `@selected`, `@messages` | `session:events` | `ScrollToBottom` |
| `/demo` | `DemoLive` | `@join_count` | `demo:joins` | — |
| `/join/:hash` | `JoinLive` | `@config`, `@expired` | — | `Clipboard` |
| `/settings` | `SettingsLive` | `@settings`, `@dirty`, `@connection_status` | — | — |

---

## Conversion checklist (per page)

```
[ ] Route: live "/path", FooLive in router.ex
[ ] Module: lib/viche_web/live/foo_live.ex
    [ ] mount/3 — assigns + PubSub subscribe
    [ ] handle_event/3 — user interactions
    [ ] handle_info/2 — PubSub + timers
    [ ] handle_params/3 — URL params if needed
[ ] Template: lib/viche_web/live/foo_live.html.heex
    [ ] onclick → phx-click
    [ ] JS variables → @assigns
    [ ] for loops → HEEx for
    [ ] CSS var() → Tailwind ef-* utilities
    [ ] Uses <Layouts.mission_control> wrapper
[ ] JS hooks: assets/js/hooks/ (if D3, clipboard, scroll needed)
[ ] PubSub topics documented and subscribed
[ ] mix phx.routes — route visible
[ ] mix phx.server — loads in browser, no console errors
```

---

## File structure

```
lib/viche_web/
├── live/
│   ├── dashboard_live.ex + .html.heex
│   ├── network_live.ex + .html.heex
│   ├── agents_live.ex + .html.heex
│   ├── agent_detail_live.ex + .html.heex
│   ├── sessions_live.ex + .html.heex
│   ├── demo_live.ex + .html.heex
│   ├── join_live.ex + .html.heex
│   └── settings_live.ex + .html.heex
├── components/
│   ├── mc_components.ex          ← new: status_pill, cap_tag, live_dot, agent_avatar
│   ├── layouts.ex                ← extend with mission_control/1
│   └── layouts/
│       ├── root.html.heex        ← existing
│       └── mission_control.html.heex  ← new
assets/
├── css/app.css                   ← add @theme Everforest tokens
└── js/
    ├── app.js                    ← register hooks
    └── hooks/
        ├── network_graph.js      ← D3 force sim
        ├── clipboard.js          ← copy to clipboard
        └── scroll_to_bottom.js   ← session auto-scroll
```
