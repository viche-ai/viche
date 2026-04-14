defmodule VicheWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VicheWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/dashboard" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the registry selector dropdown used in the sidebar of every LiveView.

  Hidden entirely when `public_mode` is true.

  ## Examples

      <Layouts.registry_selector
        selected_registry={@selected_registry}
        registries={@registries}
        public_mode={@public_mode}
      />

  """
  attr :selected_registry, :string, required: true
  attr :registries, :list, default: []
  attr :registry_names, :map, default: %{}
  attr :public_mode, :boolean, default: false

  def registry_selector(assigns) do
    ~H"""
    <%= unless @public_mode do %>
      <div
        class="px-2 pt-1 pb-1 text-[10px] font-semibold uppercase tracking-wider"
        style="color:var(--fg-dim)"
      >
        Registry
      </div>
      <form phx-change="select_registry" id="registry-selector-form">
        <div class="px-2 mb-1">
          <select
            id="registry-selector"
            name="registry"
            class="w-full text-[11px] font-mono rounded px-2 py-1"
            style="background:var(--bg-2);color:var(--fg);border:1px solid var(--border)"
          >
            <option value="global" selected={@selected_registry == "global"}>global</option>
            <option
              :for={reg <- @registries}
              :if={reg not in ["global", "all"]}
              value={reg}
              selected={@selected_registry == reg}
            >
              {Map.get(@registry_names, reg, reg)}
            </option>
            <option :if={@registries != []} value="all" selected={@selected_registry == "all"}>
              All registries
            </option>
          </select>
        </div>
      </form>
      <div class="my-1 mx-2" style="border-top:1px solid var(--border)"></div>
    <% end %>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders the shared app sidebar (mobile backdrop + `<aside>`) used by all LiveViews.

  The `active_page` atom determines which nav item receives the active highlight style
  (green left border). All other nav items are rendered as `<.link>` elements.

  The `session_count` badge is only visible on the Inboxes item when
  `active_page == :sessions` and `session_count > 0`.

  ## Examples

      <Layouts.sidebar
        active_page={:dashboard}
        selected_registry={@selected_registry}
        registries={@registries}
        public_mode={@public_mode}
        mobile_menu_open={@mobile_menu_open}
        agent_count={@agent_count}
      />

  """
  attr :active_page, :atom,
    required: true,
    values: [:dashboard, :network, :agents, :agent_detail, :sessions, :registries],
    doc: "which nav item is highlighted as active"

  attr :selected_registry, :string, required: true, doc: "registry token appended to nav links"
  attr :registries, :list, default: [], doc: "list of registry tokens for the registry selector"
  attr :registry_names, :map, default: %{}, doc: "map of registry ID to human-readable name"
  attr :public_mode, :boolean, default: false, doc: "hides the registry selector when true"
  attr :mobile_menu_open, :boolean, default: false, doc: "whether the mobile slide-out is open"
  attr :agent_count, :integer, default: 0, doc: "badge shown next to All Agents"

  attr :session_count, :integer,
    default: 0,
    doc: "badge shown on Inboxes when active_page is :sessions"

  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    ~H"""
    <%!-- MOBILE BACKDROP --%>
    <%= if @mobile_menu_open do %>
      <div class="mobile-sidebar-backdrop md:hidden" phx-click="toggle_mobile_menu"></div>
    <% end %>

    <%!-- SIDEBAR --%>
    <aside
      style="background:var(--bg-1);border-right:1px solid var(--border)"
      class={["app-sidebar w-[216px] min-w-[216px] flex flex-col", @mobile_menu_open && "open"]}
    >
      <%!-- Logo --%>
      <div class="px-4 py-4 flex items-center gap-2">
        <div class="w-7 h-7 rounded-md overflow-hidden flex-shrink-0">
          <img src="/images/viche-logo.png" alt="Viche" class="w-full h-full object-cover" />
        </div>
        <span class="text-[15px] font-semibold tracking-tight" style="color:var(--fg)">Viche</span>
        <span class="text-[10px] font-mono ml-auto" style="color:var(--fg-dim)">v0.1.0-alpha</span>
      </div>

      <%!-- Nav --%>
      <nav class="flex-1 flex flex-col px-2 gap-0.5 mt-1">
        <%!-- Registry Selector --%>
        <Layouts.registry_selector
          selected_registry={@selected_registry}
          registries={@registries}
          registry_names={@registry_names}
          public_mode={@public_mode}
        />

        <%= if @active_page == :dashboard do %>
          <div
            class="nav-item active"
            style="border-left:2px solid var(--color-ef-green);padding-left:6px"
          >
            <.icon name="hero-squares-2x2-micro" class="size-4" />
            <span>Dashboard</span>
          </div>
        <% else %>
          <.link navigate={~p"/dashboard?registry=#{@selected_registry}"} class="nav-item">
            <.icon name="hero-squares-2x2-micro" class="size-4" />
            <span>Dashboard</span>
          </.link>
        <% end %>

        <%= if @active_page == :network do %>
          <div
            class="nav-item active"
            style="border-left:2px solid var(--color-ef-green);padding-left:6px"
          >
            <.icon name="hero-signal-micro" class="size-4" />
            <span>Network</span>
          </div>
        <% else %>
          <.link navigate={~p"/network?registry=#{@selected_registry}"} class="nav-item">
            <.icon name="hero-signal-micro" class="size-4" />
            <span>Network</span>
          </.link>
        <% end %>

        <div class="my-1 mx-2" style="border-top:1px solid var(--border)"></div>

        <div
          class="px-2 pt-3 pb-1 text-[10px] font-semibold uppercase tracking-wider"
          style="color:var(--fg-dim)"
        >
          Agents
        </div>

        <%= if @active_page in [:agents, :agent_detail] do %>
          <div
            class="nav-item active"
            style="border-left:2px solid var(--color-ef-green);padding-left:6px"
          >
            <.icon name="hero-users-micro" class="size-4" />
            <span class="flex-1">All Agents</span>
            <span
              class="text-[10px] font-mono px-1.5 rounded ml-auto"
              style="background:var(--bg-2);color:var(--fg-dim)"
            >
              {@agent_count}
            </span>
          </div>
        <% else %>
          <.link navigate={~p"/agents?registry=#{@selected_registry}"} class="nav-item">
            <.icon name="hero-users-micro" class="size-4" />
            <span class="flex-1">All Agents</span>
            <span
              class="text-[10px] font-mono px-1.5 rounded ml-auto"
              style="background:var(--bg-2);color:var(--fg-dim)"
            >
              {@agent_count}
            </span>
          </.link>
        <% end %>

        <%= if @active_page == :sessions do %>
          <div
            class="nav-item active"
            style="border-left:2px solid var(--color-ef-green);padding-left:6px"
          >
            <.icon name="hero-envelope-micro" class="size-4" />
            <span class="flex-1">Inboxes</span>
            <%= if @session_count > 0 do %>
              <span
                class="text-[10px] font-mono px-1.5 rounded ml-auto"
                style="background:color-mix(in srgb,var(--color-ef-green) 18%,transparent);color:var(--color-ef-green)"
              >
                {@session_count}
              </span>
            <% end %>
          </div>
        <% else %>
          <.link navigate={~p"/sessions?registry=#{@selected_registry}"} class="nav-item">
            <.icon name="hero-envelope-micro" class="size-4" />
            <span>Inboxes</span>
          </.link>
        <% end %>

        <%= if @active_page == :registries do %>
          <div
            class="nav-item active"
            style="border-left:2px solid var(--color-ef-green);padding-left:6px"
          >
            <.icon name="hero-folder-open-micro" class="size-4" />
            <span>My Registries</span>
          </div>
        <% else %>
          <.link navigate={~p"/registries"} class="nav-item">
            <.icon name="hero-folder-open-micro" class="size-4" />
            <span>My Registries</span>
          </.link>
        <% end %>

        <div class="flex-1"></div>

        <a
          href="https://github.com/viche-ai/viche"
          target="_blank"
          rel="noopener"
          class="nav-item mb-2"
        >
          <.icon name="hero-code-bracket-micro" class="size-4" />
          <span>GitHub</span>
        </a>
      </nav>
    </aside>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Renders the shared status bar shown at the bottom of every page.

  Shows the instance type (Production vs Self-hosted), the current registry,
  and the number of connected agents.

  ## Examples

      <Layouts.status_bar hosted={@hosted} selected_registry={@selected_registry} agent_count={@agent_count} />

  """
  attr :hosted, :boolean, required: true, doc: "whether this is the hosted viche.ai instance"
  attr :selected_registry, :string, required: true, doc: "current registry name"
  attr :agent_count, :integer, required: true, doc: "agents in current registry"

  def status_bar(assigns) do
    ~H"""
    <div
      class="h-6 flex items-center px-3 md:px-4 gap-2 md:gap-3 text-[10px] font-mono border-t flex-shrink-0"
      style="background:var(--bg-1);border-color:var(--border);color:var(--fg-dim)"
    >
      <span class="w-1.5 h-1.5 rounded-full bg-[var(--color-ef-green)] animate-pulse inline-block">
      </span>
      <span>{if @hosted, do: "Production", else: "Self-hosted"}</span>
      <span class="opacity-30">|</span>
      <span>registry: {@selected_registry}</span>
      <span class="opacity-30">|</span>
      <span>{@agent_count} agents</span>
    </div>
    """
  end
end
