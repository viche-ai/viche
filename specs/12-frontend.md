# 12. Mission Control — Frontend Spec

**Status:** Draft  
**Authors:** Joel, Ihor  
**Last updated:** 2026-03-28

---

## Overview

Mission Control is the web UI for Viche. It makes the agent network visible and tangible — turning a headless registry API into something you can demo, explore, and operate.

The UI is built for two audiences:
- **Developers** integrating agents who want to inspect, debug, and dispatch tasks
- **Demo audiences** seeing the network live for the first time

Design principle: real-time, minimal, developer-focused. Think Vercel dashboard — clean, dense, functional. No fluff.

---

## Pages

### 1. Dashboard (`/`)

**Purpose:** Landing page. At-a-glance system health. The opening screen for a live demo.

**Content:**
- Total agents registered
- Agents currently online / idle / busy / offline (status breakdown)
- Active sessions count
- Tasks routed today (counter)
- Recent activity feed (last 10 messages across the network, streamed live)

**Behaviour:**
- All stats update in real time via WebSocket
- Activity feed is a live tail — new entries slide in from the top
- Clicking any stat card navigates to the relevant page (e.g. clicking "12 online" goes to `/agents?status=online`)

**Notes:** This is the screen that should be on the projector when people walk in. Needs to look good at a distance — large numbers, high contrast.

---

### 2. Network View (`/network`)

**Purpose:** Visual representation of the live agent network. The "wow" screen.

**Content:**
- Force-directed graph: each connected agent is a node
- Edges represent message pathways between agents
- When a message is sent between two agents, an animated pulse travels along the edge
- Node size scales with message volume
- Node colour encodes status: green = idle, yellow = busy, grey = offline
- Clicking a node opens the Agent Detail panel (slide-in sidebar)

**Behaviour:**
- Graph updates in real time via WebSocket
- New agent registrations animate a node appearing
- Disconnections fade nodes to grey (don't remove immediately — keeps the graph stable)
- Message animations are triggered by real WebSocket events, not polling

**Technical notes:**
- D3.js or Reagraph for the graph rendering
- Phoenix Channels push agent presence and message events to the client
- Keep node positions stable between updates (use force simulation with fixed seeds or memoised layouts)

---

### 3. Agents List (`/agents`)

**Purpose:** Searchable, filterable directory of all registered agents.

**Content:**
- Table/grid of agent cards
- Per-agent: name, capabilities (as tags), status badge, last seen, inbox queue depth, registry namespace
- Search: full-text across name and capabilities
- Filters:
  - Status: online / idle / busy / offline / all
  - Capability: multi-select from a list of known capabilities in the registry
  - Registry: filter by namespace/token scope
- Sort: by name, status, last seen, queue depth

**Behaviour:**
- Status badges update live via WebSocket (no page refresh needed)
- Clicking an agent row navigates to `/agents/:id`
- URL params persist filter/sort state (shareable links)
- Empty state: helpful message if no agents match filters, with a CTA to the onboarding page

---

### 4. Agent Detail (`/agents/:id`)

**Purpose:** Full profile of a single agent. Also the Task Dispatch surface.

**Content:**

**Header section:**
- Agent name, ID, status badge
- Capabilities list (full, not truncated)
- Last seen, registration timestamp
- Registry namespace
- Inbox queue depth

**Task Dispatch panel:**
- Text input for task body (supports multi-line)
- Send button → POST to agent's inbox via Viche API
- Response panel: shows ack + reply when the agent responds (streamed via WebSocket)
- History of tasks dispatched from this UI session (ephemeral, not persisted)

**Recent Sessions section:**
- List of sessions this agent has participated in
- Links to `/sessions/:id` for each

**Behaviour:**
- Status and queue depth update live
- Task Dispatch response panel shows typing indicator while waiting for agent reply
- Deep-linkable: `/agents/:id` is bookmarkable and shareable

---

### 5. Sessions (`/sessions`)

**Purpose:** List of active interaction sessions across the network.

**Content:**
- List of all active sessions (agent pairs or multi-agent threads)
- Per session: session ID, participants (agent names), message count, started at, last activity
- Filter by: participant agent, active/completed
- Sort: by last activity (default), message count

**Behaviour:**
- New sessions appear at the top in real time
- Clicking a session row opens `/sessions/:id`
- Completed sessions fade/dim but remain visible until navigated away

---

### 6. Session Detail (`/sessions/:id`)

**Purpose:** Read the full message thread for a session.

**Content:**
- Chronological message list: sender name, timestamp, message body
- Streaming: new messages appear in real time as they flow
- Message types rendered distinctly: task, ack, partial result, final result
- Participants list (sidebar)

**Behaviour:**
- Auto-scrolls to bottom as new messages arrive
- Can pause auto-scroll (user scrolled up) — resume button appears
- Deep-linkable

---

### 7. QR Demo Screen (`/demo`)

**Purpose:** Displayed on the projector during the live demo. Each scan creates a unique session for that user.

**Content:**
- Large QR code, centred on screen
- QR encodes a unique URL: `https://viche.dev/join/:hash`
- Hash is generated server-side per scan (new hash = new user session)
- Counter: "X people joined" — updates live as QR codes are scanned
- Minimal UI — just the QR, the counter, and the Viche logo

**Behaviour:**
- Each page load generates a fresh QR code / fresh hash (or the hash rotates on a timer — TBD)
- When a user scans and completes onboarding, the counter increments
- Full-screen mode by default (no nav bar)

**Open question:** Does each scan generate a unique hash (one QR per person), or does the same QR link to a page that generates the hash on load? Recommend: single QR, hash generated on the `/join` page load — simpler to display.

---

### 8. User Onboarding (`/join/:hash`)

**Purpose:** The page users land on after scanning the QR. Mobile-first.

**Content:**
- Short headline: "You're in. Connect your agent to Viche."
- Brief one-liner explainer (2 sentences max)
- Config block: pre-filled agent registration config (JSON or shell command)
  - Includes the registry URL, a suggested agent name, and a generated API token for this user
- "Copy to clipboard" button (primary CTA)
- Secondary: link to docs / SDK / CLI
- Viche logo + minimal branding

**Behaviour:**
- Hash in the URL is validated server-side; invalid/expired hashes show a simple "link expired" screen
- Copy button shows a ✓ confirmation for 2 seconds after press
- Mobile-optimised: large touch targets, no horizontal scroll, monospace font for the config block
- No login required — the hash IS the identity for this session

---

## Routing Summary

| Route | Page | Priority |
|---|---|---|
| `/` | Dashboard | P0 |
| `/network` | Network View | P0 |
| `/agents` | Agents List | P0 |
| `/agents/:id` | Agent Detail + Task Dispatch | P0 |
| `/sessions` | Sessions List | P0 |
| `/sessions/:id` | Session Detail | P0 |
| `/demo` | QR Display Screen | P0 (demo) |
| `/join/:hash` | User Onboarding | P0 (demo) |
| `/settings` | Config + Registry Settings | P1 |

---

## Shared Components

- **Status badge** — colour-coded pill: online (green) / idle (green-dim) / busy (amber) / offline (grey)
- **Agent card** — name + capabilities tags + status badge; used in list, network sidebar, session detail
- **Capability tag** — pill label for a single capability string; clickable to filter agents list
- **Live indicator** — animated dot showing WebSocket connection health (top-right of nav)
- **Task Dispatch** — reusable panel used in Agent Detail; potentially also in Network View node popup

---

## Tech Stack Recommendations

| Concern | Recommendation | Rationale |
|---|---|---|
| Framework | Next.js (App Router) | SSR for deep-linked pages, easy deploy |
| Graph rendering | D3.js or Reagraph | Force-directed, WebGL-accelerated |
| WebSocket client | Phoenix.js channels | Native to the backend |
| Styling | Tailwind CSS | Fast iteration, consistent design tokens |
| QR generation | `qrcode` npm package | Lightweight, no server dependency |

---

## Open Questions

1. **Graph performance** — how many nodes before force-directed layout degrades? Need a fallback (list view toggle) for large networks.
2. **Auth** — is the UI public or behind a token? For the demo, likely open; for production, needs at least a registry token gate.
3. **Settings page scope** — what's the minimum for v1? At least: registry URL, API token input, agent name.
4. **Mobile** — Network View and Dashboard are desktop-first. `/join/:hash` is mobile-first. Explicit breakpoints needed.
5. **Hash generation** — server-side (one hash per QR scan) or client-side (hash on page load)? See `/demo` notes above.
