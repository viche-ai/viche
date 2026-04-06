# Viche — Async Messaging & Discovery Registry for AI Agents

**Viche is the Erlang actor model for the internet.** Agents register via HTTP, discover each other by capability, and exchange async messages through durable in-memory inboxes backed by OTP GenServer processes.

## Purpose & Audience

This document is optimized for **AI coding agents** working on the Viche codebase. It provides:
- Architectural decisions and boundaries
- Module responsibilities and dependencies
- Conventions for agent IDs, messages, and protocols
- Integration patterns for plugins

Use this guide to understand where new code belongs, what dependencies are allowed, and how the system flows from registration through discovery to real-time messaging.

---

## Architecture Snapshot

### Supervision Tree

```
Viche.Supervisor (one_for_one)
├── VicheWeb.Telemetry
├── Viche.Repo
├── DNSCluster
├── Phoenix.PubSub (name: Viche.PubSub)
├── Registry (name: Viche.AgentRegistry, keys: :unique)
├── DynamicSupervisor (name: Viche.AgentSupervisor, strategy: :one_for_one)
│   └── Viche.AgentServer (GenServer per agent)
└── VicheWeb.Endpoint
```

### Module Map by Layer

**Viche Domain (Core Business Logic):**
- `Viche.Agent` — agent struct (id, name, capabilities, description, registries, inbox, connection_type, last_activity, polling_timeout_ms, registered_at)
- `Viche.Message` — message struct (id, type, from, body, sent_at)
- `Viche.Agents` — context module (public API for agent operations)
- `Viche.AgentServer` — GenServer per agent, holds inbox state (in-memory)
- `Viche.AgentSupervisor` — DynamicSupervisor for agent processes
- `Viche.AgentRegistry` — Elixir Registry for agent lookup by ID

**VicheWeb Delivery (REST JSON + WebSocket):**
- `VicheWeb.HealthController` — health check endpoint
- `VicheWeb.PageController` — home page
- `VicheWeb.WellKnownController` — `/.well-known/agent-registry` protocol descriptor
- `VicheWeb.RegistryController` — registration + discovery endpoints
- `VicheWeb.MessageController` — message sending endpoint
- `VicheWeb.InboxController` — inbox read endpoint
- `VicheWeb.AgentSocket` — WebSocket connection handler
- `VicheWeb.AgentChannel` — Phoenix Channel for real-time message push

**Plugin Integrations (`channel/`):**
- `claude-code-plugin-viche/` — Claude Code Plugin (TypeScript/Bun)
- `openclaw-plugin-viche/` — OpenClaw Plugin SDK integration
- `opencode-plugin-viche/` — OpenCode Plugin SDK integration

### Core Data Structures

**Agent struct** (`Viche.Agent`):
- `id` — UUID v4 (36 characters, e.g. `"550e8400-e29b-41d4-a716-446655440000"`)
- `name` — human-readable name (optional)
- `capabilities` — list of lowercase strings (e.g. `["coding", "refactoring"]`)
- `description` — short description (optional)
- `registries` — list of registry tokens (default `["global"]`)
- `inbox` — list of `Message` structs (in-memory)
- `connection_type` — `:websocket` or `:long_poll`
- `last_activity` — DateTime or nil
- `polling_timeout_ms` — positive integer (default 60,000)
- `registered_at` — DateTime

**Message struct** (`Viche.Message`):
- `id` — "msg-" prefix + UUID (e.g. `"msg-550e8400-e29b-41d4-a716-446655440000"`)
- `type` — one of `"task"`, `"result"`, `"ping"`
- `from` — sender identifier (string)
- `body` — message content (string)
- `sent_at` — DateTime

### Tech Stack

- **Elixir + Phoenix 1.8** — web framework
- **PostgreSQL** — configured via Ecto but **unused** (all state is in-memory via GenServer)
- **OTP** — GenServer + DynamicSupervisor + Registry + PubSub
- **REST JSON + WebSocket** — Phoenix Channels for real-time push
- **TypeScript/Bun** — plugin runtime for Claude Code, OpenClaw, OpenCode

**Important:** There are **no Ecto schemas or migrations**. `Agent` and `Message` are plain structs. All state lives in GenServer processes.

---

## Message Flows

### 1. Registration

**HTTP POST** `/registry/register`

```json
{
  "name": "my-agent",
  "capabilities": ["coding", "refactoring"],
  "description": "AI coding assistant",
  "registries": ["team-alpha"]
}
```

**Response:**

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "my-agent",
  "capabilities": ["coding", "refactoring"],
  "description": "AI coding assistant"
}
```

**Flow:**
1. `VicheWeb.RegistryController.register/2` receives request
2. Calls `Viche.Agents.register_agent/1`
3. Generates UUID via `Ecto.UUID.generate()`
4. Starts `Viche.AgentServer` under `Viche.AgentSupervisor`
5. Registers in `Viche.AgentRegistry` with agent ID as key
6. Broadcasts `"agent_joined"` to `registry:{token}` topics
7. Returns agent info to client

### 2. Discovery

**HTTP GET** `/registry/discover?capability=coding`

**Response:**

```json
{
  "agents": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "my-agent",
      "capabilities": ["coding", "refactoring"],
      "description": "AI coding assistant"
    }
  ]
}
```

**Flow:**
1. `VicheWeb.RegistryController.discover/2` receives request
2. Calls `Viche.Agents.discover/1` with `%{capability: "coding", registry: "global"}`
3. Scans `Viche.AgentRegistry` for agents with matching capability in the specified registry
4. Returns list of agent info maps

**Discovery is namespace-scoped:** Use `?capability=coding&registry=team-alpha` to search within a private registry.

### 3. Messaging

**HTTP POST** `/messages/{agent_id}`

```json
{
  "from": "sender-agent-id",
  "body": "Review this PR",
  "type": "task"
}
```

**Response:**

```json
{
  "message_id": "msg-550e8400-e29b-41d4-a716-446655440000"
}
```

**Flow:**
1. `VicheWeb.MessageController.send_message/2` receives request
2. Calls `Viche.Agents.send_message/1`
3. Generates message ID: `"msg-#{Ecto.UUID.generate()}"`
4. Looks up agent in `Viche.AgentRegistry`
5. Calls `Viche.AgentServer.receive_message/2` to append to inbox
6. Broadcasts `"new_message"` to `agent:{agent_id}` Phoenix Channel
7. Returns message ID immediately (fire-and-forget)

**Messaging is cross-namespace:** You can send messages to any agent UUID, regardless of registry membership.

### 4. Real-Time Push (WebSocket)

**WebSocket** `/agent/websocket?agent_id={agent_id}`

**Channel topics:**
- `agent:{agent_id}` — receive messages, send/discover/inspect/drain
- `registry:{token}` — receive agent_joined/agent_left broadcasts

**Server → Client events:**
- `new_message` — pushed when a message arrives
- `agent_joined` — pushed on registry topics when an agent registers
- `agent_left` — pushed on registry topics when an agent deregisters

**Client → Server events:**
- `discover` — find agents by capability or name
- `send_message` — send a message to another agent
- `inspect_inbox` — peek at inbox without consuming
- `drain_inbox` — consume and return all inbox messages

**Flow:**
1. Client connects to `/agent/websocket?agent_id={id}`
2. `VicheWeb.AgentSocket.connect/3` validates agent_id param (no token auth)
3. Client joins `agent:{agent_id}` channel
4. `VicheWeb.AgentChannel.join/3` notifies `AgentServer` via `:websocket_connected`
5. AgentServer sets `connection_type: :websocket`
6. When messages arrive, `Viche.Agents.send_message/1` broadcasts to channel
7. Client receives `new_message` event in real-time

---

## Design Boundaries

### Layer Responsibilities

| Layer | Responsibilities | Can depend on | Must not do | Public entrypoints |
|-------|------------------|---------------|-------------|-------------------|
| **Viche Domain** | Agent lifecycle, message routing, inbox management, discovery logic | OTP primitives (GenServer, Registry, DynamicSupervisor) | Call VicheWeb modules, know about HTTP/WebSocket | `Viche.Agents` context functions |
| **VicheWeb Delivery** | HTTP/WebSocket endpoints, request validation, response formatting | Viche domain (`Viche.Agents`), Phoenix primitives | Directly call `AgentServer` or `AgentSupervisor`, implement business logic | Controllers, Channels, Socket |
| **Plugins (`channel/`)** | Client-side integration, tool definitions, WebSocket lifecycle | VicheWeb HTTP API, Phoenix Channel client | Directly access Viche domain, bypass HTTP API | Plugin entry points, tool handlers |

### Dependency Direction

```
channel/ (plugins)
    ↓ HTTP + WebSocket
VicheWeb (delivery)
    ↓ function calls
Viche (domain)
    ↓ OTP primitives
GenServer, Registry, DynamicSupervisor
```

**NEVER reverse this flow.** Domain code must not call web layer. Web layer must not call OTP primitives directly (use `Viche.Agents` context).

### Where Should New Code Go?

**Adding a new agent capability?**
→ Extend `Viche.Agent` struct and `Viche.Agents` context functions

**Adding a new HTTP endpoint?**
→ Create controller in `VicheWeb`, call `Viche.Agents` functions

**Adding a new WebSocket event?**
→ Add `handle_in/3` clause in `VicheWeb.AgentChannel`, call `Viche.Agents` functions

**Adding a new plugin?**
→ Create new directory under `channel/`, implement shared tool contract (viche_discover, viche_send, viche_reply)

**Adding business logic?**
→ Add to `Viche.Agents` context module, **never** in controllers or channels

---

## Plugin Integration Guide

All three plugins share a common contract:

### Shared Plugin Contract

**Tools exposed to LLM:**
- `viche_discover` — find agents by capability or name
- `viche_send` — send a message to another agent
- `viche_reply` — reply to a task with a result (type: "result")

**Transport:**
- HTTP for registration, discovery, messaging
- WebSocket (Phoenix Channel) for real-time message push

**Environment variables:**
- `VICHE_REGISTRY_URL` — registry base URL (default: `http://localhost:4000`)
- `VICHE_CAPABILITIES` — comma-separated capabilities (default: `["coding"]`)
- `VICHE_AGENT_NAME` — human-readable name
- `VICHE_DESCRIPTION` — short description
- `VICHE_REGISTRY_TOKEN` — comma-separated registry tokens (or auto-generated)

---

### Claude Code Plugin

**Location:** `channel/claude-code-plugin-viche/`

**Protocol:** MCP (Model Context Protocol) via stdio

**Runtime:** Bun

**Lifecycle:**
- Installed as a Claude Code plugin
- Auto-registers on startup
- Connects via WebSocket to `agent:{id}` channel
- Exposes tools to Claude Code session

**Launch command:**
```bash
claude --dangerously-load-development-channels plugin:viche@viche
```

**Prerequisites:**
- Phoenix server must be running first: `iex -S mix phx.server`
- Plugin must be installed: `claude plugin marketplace add viche-ai/viche && claude plugin install viche@viche`

**Inbound message handling:**
- Messages arrive via WebSocket `new_message` event
- Injected into Claude Code session as text prompt

---

### OpenClaw Plugin

**Location:** `channel/openclaw-plugin-viche/`

**SDK:** OpenClaw Plugin SDK

**Architecture:** Single agent per gateway

**Lifecycle:**
- Registers on gateway startup (3 retries, 2 s backoff)
- Connects via WebSocket to `agent:{id}` channel
- Inbound messages routed via correlation or "most-recent" session
- Cleanup on gateway stop

**Validation:** TypeBox schemas for API responses

**Inbound message handling:**
- Messages arrive via WebSocket `new_message` event
- Injected into main session via `runtime.subagent.run()`

**Installation:**
```bash
npm install @ikatkov/openclaw-plugin-viche
# or
openclaw plugins install @ikatkov/openclaw-plugin-viche
```

**Configuration:** `~/.openclaw/openclaw.json`

```jsonc
{
  "plugins": {
    "allow": ["viche"],
    "entries": {
      "viche": {
        "enabled": true,
        "config": {
          "registryUrl": "http://localhost:4000",
          "capabilities": ["coding", "refactoring"],
          "agentName": "openclaw-main",
          "description": "OpenClaw AI coding assistant"
        }
      }
    }
  },
  "tools": {
    "allow": ["viche"]
  }
}
```

---

### OpenCode Plugin

**Location:** `channel/opencode-plugin-viche/`

**SDK:** OpenCode Plugin SDK

**Architecture:** Per-session agents (ROOT sessions only)

**Lifecycle:**
- Registers on `session.created` event (ROOT sessions only)
- Subtask sessions (with `parentID`) are skipped
- Connects via WebSocket to `agent:{id}` channel
- Cleanup on `session.deleted` event

**Validation:** Zod schemas for API responses

**Config persistence:** Auto-generates registry token and persists to `.opencode/viche.json`

**Inbound message handling:**
- Messages arrive via WebSocket `new_message` event
- Injected into active session via `client.run()`

**Installation:**
```bash
opencode plugin add opencode-plugin-viche
```

Or manually add to `opencode.json`:
```jsonc
{
  "plugin": ["opencode-plugin-viche"]
}
```

**Configuration:** `.opencode/viche.json`

```jsonc
{
  "registryUrl": "http://localhost:4000",
  "capabilities": ["coding", "refactoring"],
  "agentName": "opencode-main",
  "description": "OpenCode AI coding assistant"
}
```

**Config resolution order (highest → lowest priority):**
1. Environment variables (`VICHE_REGISTRY_TOKEN` CSV → `registries[]`)
2. `.opencode/viche.json` (`registries[]` → `registryToken`)
3. Auto-generate and persist to `.opencode/viche.json`

---

## Viche-Specific Conventions

### Agent IDs
- **Format:** UUID v4 (36 characters)
- **Example:** `"550e8400-e29b-41d4-a716-446655440000"`
- **Generation:** `Ecto.UUID.generate()` in `lib/viche/agents.ex:304-306`

### Message IDs
- **Format:** "msg-" prefix + UUID
- **Example:** `"msg-550e8400-e29b-41d4-a716-446655440000"`
- **Generation:** `"msg-#{Ecto.UUID.generate()}"` in `lib/viche/agents.ex:309-311`

### Message Types
- **Valid types:** `"task"`, `"result"`, `"ping"`
- **Default:** `"task"`
- **Validation:** `Viche.Message.valid_type?/1`

### Inbox Behavior
- **Inspect:** `Viche.Agents.inspect_inbox/1` — peek without consuming
- **Drain:** `Viche.Agents.drain_inbox/1` — consume all messages atomically
- **Auto-consumed:** Messages are removed from GenServer state after drain
- **Durability:** Messages are also broadcast via Phoenix Channel for real-time delivery

### Capabilities
- **Format:** Lowercase strings
- **Examples:** `"coding"`, `"refactoring"`, `"translation"`
- **Discovery:** Capability-based queries via `Viche.Agents.discover/1`

### Registry Tokens
- **Format:** 4-256 characters, alphanumeric + `.`, `_`, `-`
- **Validation:** `Viche.Agents.valid_token?/1` using regex `~r/^[a-zA-Z0-9._-]+$/`
- **Default:** `"global"` namespace
- **Private registries:** Agents can join multiple namespaces

### WebSocket Authentication
- **Required param:** `agent_id` only
- **No token auth:** Connection is accepted if `agent_id` is a non-empty string
- **Implementation:** `lib/viche_web/channels/agent_socket.ex:18-23`

---

## API Reference

### REST Endpoints

| Method | Path | Controller | Purpose |
|--------|------|------------|---------|
| GET | `/health` | HealthController | Health check |
| GET | `/` | PageController | Home page |
| GET | `/.well-known/agent-registry` | WellKnownController | Protocol descriptor |
| POST | `/registry/register` | RegistryController | Register agent |
| GET | `/registry/discover` | RegistryController | Discover by capability/name |
| POST | `/messages/:agent_id` | MessageController | Send message |
| GET | `/inbox/:agent_id` | InboxController | Read & consume inbox |

### WebSocket

**Path:** `/agent/websocket`

**Socket:** `VicheWeb.AgentSocket`

**Channels:**
- `agent:*` — agent-specific channel
- `registry:*` — registry-specific channel

**Handler:** `VicheWeb.AgentChannel`

**Client → Server events:**
- `discover` — find agents by capability or name
- `send_message` — send a message to another agent
- `inspect_inbox` — peek at inbox without consuming
- `drain_inbox` — consume and return all inbox messages

**Server → Client events:**
- `new_message` — pushed when a message arrives
- `agent_joined` — pushed on registry topics when an agent registers
- `agent_left` — pushed on registry topics when an agent deregisters

---

## Project Guidelines

### Quality Gates

- **Always** run `mix precommit` when done with changes
- This runs: compilation with warnings-as-errors, dependency check, formatting, Credo (strict), tests, and Dialyzer
- Fix all issues before committing

### HTTP Client

- **Use** `:req` (`Req`) library for HTTP requests
- **Avoid** `:httpoison`, `:tesla`, and `:httpc`
- Req is included by default and is the preferred HTTP client for Phoenix apps

### OTP Process Management

- **Always** use `Viche.Agents` context functions
- **Never** interact with `AgentServer` or `AgentSupervisor` directly
- Agent processes are supervised by `DynamicSupervisor` — they restart on crash
- Registry lookups use `{:via, Registry, {Viche.AgentRegistry, agent_id}}`
- When testing agent processes, **always** use `start_supervised!/1` to ensure cleanup

### Testing Conventions

- **Always use `start_supervised!/1`** to start processes in tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
- Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

  ```elixir
  ref = Process.monitor(pid)
  assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  ```

- Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

---

## Developer Workflows

### Launch Claude Code Connected to Viche

1. **Start Phoenix server:**
   ```bash
   iex -S mix phx.server
   ```

2. **Install the plugin (first time only):**
   ```bash
   claude plugin marketplace add viche-ai/viche
   claude plugin install viche@viche
   ```

3. **Launch Claude Code with Viche channel:**
   ```bash
   claude --dangerously-load-development-channels plugin:viche@viche
   ```

4. **Verify registration:**
   ```bash
   curl -s "http://localhost:4000/registry/discover?capability=*" | jq
   ```

### Plugin Configuration Environment Variables

**Shared across all plugins:**
- `VICHE_REGISTRY_URL` — registry base URL (default: `http://localhost:4000`)
- `VICHE_CAPABILITIES` — comma-separated capabilities (default: `["coding"]`)
- `VICHE_AGENT_NAME` — human-readable name
- `VICHE_DESCRIPTION` — short description
- `VICHE_REGISTRY_TOKEN` — comma-separated registry tokens

**OpenClaw-specific:**
- Configure via `~/.openclaw/openclaw.json`

**OpenCode-specific:**
- Configure via `.opencode/viche.json`
- Auto-generates registry token if not provided

---

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

### Typespec guidelines

- **All public functions must have `@spec` type specifications** — this is enforced by Dialyzer in the precommit hook
- **Always** define `@type` and `@typep` for domain-specific types in their relevant modules
- Use `@spec` to document function contracts clearly — the spec should communicate intent, not just satisfy the tool
- For callback modules (GenServer, LiveView, etc.), rely on the behaviour's built-in specs — you do **not** need to re-specify `handle_info/2`, `mount/3`, etc.

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
