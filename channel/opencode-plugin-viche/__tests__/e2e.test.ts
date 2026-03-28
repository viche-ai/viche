/**
 * E2E tests for opencode-plugin-viche against the live Viche server.
 *
 * Prerequisites:
 *   - Viche Phoenix server running at http://localhost:4000
 *   - Verified by: curl -s http://localhost:4000/.well-known/agent-registry
 *
 * These tests exercise the full plugin stack against the real server:
 *   - Real HTTP calls (fetch) to register, discover, send, and read inbox
 *   - Real Phoenix WebSocket for inbound message push
 *   - The mock only covers the OpenCode SDK client (session.prompt / promptAsync)
 *
 * Module isolation note (bun v1.3.5):
 *   bun:test runs all test files in the SAME process. mock.module("phoenix", ...)
 *   in index.test.ts and service.test.ts bleeds into this file, replacing the real
 *   Phoenix Socket with a fake one.
 *
 *   Fix: in beforeAll we import phoenix via its ABSOLUTE FILE PATH (a file:// URL).
 *   bun's mock.module is keyed on the package name "phoenix", not the file path, so
 *   the absolute-path import always returns the real CJS module. We then call
 *   mock.module("phoenix", realSocket) to re-pin the real Socket before loading
 *   index.js — ensuring the plugin always uses a real WebSocket connection.
 */

import { describe, it, expect, beforeAll, afterAll, mock } from "bun:test";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BASE_URL = "http://localhost:4000";

// Unique session ID per test run to avoid cross-run interference.
const SESSION_ID = `e2e-session-${Date.now()}`;

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** POST to /registry/register and return the assigned agent ID. */
async function registerAgent(capabilities: string[], name?: string): Promise<string> {
  const body: Record<string, unknown> = { capabilities };
  if (name) body.name = name;
  const resp = await fetch(`${BASE_URL}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(`Registration failed: ${resp.status}`);
  const { id } = (await resp.json()) as { id: string };
  return id;
}

/** GET /inbox/:agentId and return the messages array. */
async function drainInbox(
  agentId: string
): Promise<Array<{ id: string; from: string; body: string; type: string; sent_at: string }>> {
  const resp = await fetch(`${BASE_URL}/inbox/${agentId}`);
  if (!resp.ok) throw new Error(`Inbox read failed: ${resp.status}`);
  const { messages } = (await resp.json()) as {
    messages: Array<{ id: string; from: string; body: string; type: string; sent_at: string }>;
  };
  return messages;
}

// ---------------------------------------------------------------------------
// Shared mock client
// ---------------------------------------------------------------------------

const mockClient = {
  session: {
    prompt: mock(() => Promise.resolve()),
    promptAsync: mock(() => Promise.resolve()),
  },
};

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

type ToolDef = {
  description: string;
  parameters: Record<string, unknown>;
  execute: (args: Record<string, unknown>, ctx: { sessionID: string }) => Promise<string>;
};

type Hooks = {
  event: (input: { event: { type: string; properties?: Record<string, unknown> } }) => Promise<void>;
  tool: Record<string, unknown>;
};

describe("E2E: opencode-plugin-viche against live Viche server", () => {
  let hooks: Hooks;
  let ourAgentId: string;

  // ── Setup: register agent + connect WebSocket ────────────────────────────

  beforeAll(async () => {
    // ── Step 1: Re-pin the REAL Phoenix Socket ─────────────────────────────
    //
    // bun:test shares a module registry across files in the same run. Other
    // test files call mock.module("phoenix", MockSocket) which replaces the
    // real Socket for EVERYONE. We fix this by importing phoenix directly via
    // its absolute file path (bypasses mock.module's package-name keying) and
    // then re-registering the real Socket so the next import of index.js gets it.
    const phoenixFilePath = new URL(
      "../node_modules/phoenix/priv/static/phoenix.cjs.js",
      import.meta.url
    ).href;
    const realPhoenix = await import(phoenixFilePath);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const RealSocket = (realPhoenix as any).Socket as new (...args: unknown[]) => unknown;

    mock.module("phoenix", () => ({ Socket: RealSocket }));

    // ── Step 2: Load the plugin with real Phoenix now in effect ────────────
    const { default: vichePlugin } = await import("../index.js");

    // ── Step 3: Initialize plugin + trigger session.created ────────────────
    hooks = await vichePlugin({
      client: mockClient,
      directory: "/tmp/e2e-test",
    });

    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: SESSION_ID } },
      },
    });

    // handleSessionCreated awaits registration + WebSocket join before
    // calling client.session.prompt. By here everything is live.

    // ── Step 4: Extract agent ID from identity prompt ──────────────────────
    const promptCalls = (mockClient.session.prompt as ReturnType<typeof mock>).mock.calls;
    if (promptCalls.length === 0) {
      throw new Error("session.created did not trigger client.session.prompt — is the server up?");
    }
    const firstCall = promptCalls[0] as [{ body: { parts: Array<{ text: string }> } }];
    const text = firstCall[0].body.parts[0].text;
    const match = text.match(/Your agent ID is ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/);
    if (!match) {
      throw new Error(`Could not extract agent ID from identity prompt: ${text}`);
    }
    ourAgentId = match[1];
  }, 15_000);

  // ── Teardown: disconnect + allow server to deregister ────────────────────

  afterAll(() => {
    // Best-effort cleanup (safe to call even if Test 5 already deleted the session).
    if (hooks) {
      hooks.event({
        event: {
          type: "session.deleted",
          properties: { info: { id: SESSION_ID } },
        },
      });
    }
  });

  // ── Test 1: Plugin shape ─────────────────────────────────────────────────

  it(
    "Test 1: plugin factory returns { event, tool } with all three tools",
    async () => {
      // Create a fresh instance (no session triggered — no side effects).
      const client2 = {
        session: {
          prompt: mock(() => Promise.resolve()),
          promptAsync: mock(() => Promise.resolve()),
        },
      };

      // Use the already-loaded vichePlugin (real phoenix is in effect from beforeAll).
      const { default: vichePlugin } = await import("../index.js");
      const testHooks = await vichePlugin({
        client: client2,
        directory: "/tmp/e2e-test-1",
      });

      expect(testHooks).toHaveProperty("event");
      expect(testHooks).toHaveProperty("tool");
      expect(typeof testHooks.event).toBe("function");
      expect(typeof testHooks.tool).toBe("object");
      expect(testHooks.tool).toHaveProperty("viche_discover");
      expect(testHooks.tool).toHaveProperty("viche_send");
      expect(testHooks.tool).toHaveProperty("viche_reply");
    },
    10_000
  );

  // ── Test 2: Registration + discovery ────────────────────────────────────

  it(
    "Test 2: registered agent appears in discovery results (capability='*')",
    async () => {
      expect(ourAgentId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);

      const tool = hooks.tool["viche_discover"] as ToolDef;
      const result = await tool.execute(
        { capability: "*" },
        { sessionID: SESSION_ID }
      );

      expect(result).toMatch(/Found \d+ agent\(s\)/);
      expect(result).toContain(ourAgentId);
    },
    10_000
  );

  // ── Test 3: viche_send → real inbox delivery ─────────────────────────────

  it(
    "Test 3: viche_send delivers a message to an external agent's inbox",
    async () => {
      // Register an external "target" agent directly via HTTP.
      const externalId = await registerAgent(["e2e-test-target"]);

      // Use the viche_send tool (uses ourAgentId as from, sends to externalId).
      const sendTool = hooks.tool["viche_send"] as ToolDef;
      const result = await sendTool.execute(
        { to: externalId, body: "hello from e2e", type: "task" },
        { sessionID: SESSION_ID }
      );
      expect(result).toContain("sent");

      // Read the external agent's inbox via HTTP.
      const messages = await drainInbox(externalId);

      expect(messages).toHaveLength(1);
      expect(messages[0].from).toBe(ourAgentId);
      expect(messages[0].body).toBe("hello from e2e");
      expect(messages[0].type).toBe("task");
    },
    10_000
  );

  // ── Test 4: Inbound WebSocket push → promptAsync ─────────────────────────

  it(
    "Test 4: inbound message is pushed over WebSocket and triggers client.session.promptAsync",
    async () => {
      // Clear any prior promptAsync calls so we can assert on fresh ones.
      (mockClient.session.promptAsync as ReturnType<typeof mock>).mockClear();

      // Register a "sender" agent directly via HTTP.
      const senderId = await registerAgent(["e2e-test-sender"]);

      // POST a message to our registered agent — the server will push it
      // via Phoenix Channel to our open WebSocket connection.
      const msgResp = await fetch(`${BASE_URL}/messages/${ourAgentId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          from: senderId,
          type: "task",
          body: "e2e websocket delivery test",
        }),
      });
      expect(msgResp.ok).toBe(true);

      // Allow time for the WebSocket push to arrive and be processed.
      await wait(1_000);

      const asyncCalls = (
        mockClient.session.promptAsync as ReturnType<typeof mock>
      ).mock.calls;
      expect(asyncCalls.length).toBeGreaterThan(0);

      const call = asyncCalls[0] as [{ body: { parts: Array<{ text: string }> } }];
      const text = call[0].body.parts[0].text;
      expect(text).toContain(`[Viche Task from ${senderId}]`);
      expect(text).toContain("e2e websocket delivery test");
    },
    10_000
  );

  // ── Test 5: Session cleanup → agent deregistered ─────────────────────────

  it(
    "Test 5: session.deleted disconnects WebSocket and agent is eventually deregistered",
    async () => {
      // Trigger cleanup. The plugin leaves the channel and disconnects the socket.
      // The Viche server's grace period (5 000 ms) then deregisters the agent.
      await hooks.event({
        event: {
          type: "session.deleted",
          properties: { info: { id: SESSION_ID } },
        },
      });

      // Wait for grace period + a safety buffer.
      await wait(6_000);

      // The agent should no longer appear in discovery.
      const resp = await fetch(`${BASE_URL}/registry/discover?capability=*`);
      expect(resp.ok).toBe(true);
      const { agents } = (await resp.json()) as { agents: Array<{ id: string }> };
      const found = agents.some((a) => a.id === ourAgentId);
      expect(found).toBe(false);
    },
    15_000
  );
});
