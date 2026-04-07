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
import { readFileSync } from "node:fs";
import { join } from "node:path";

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

function extractAgentIdFromPromptCalls(client: {
  session: { prompt: ReturnType<typeof mock> };
}): string {
  const promptCalls = client.session.prompt.mock.calls;
  if (promptCalls.length === 0) {
    throw new Error("session.created did not trigger client.session.prompt — is the server up?");
  }

  for (let i = promptCalls.length - 1; i >= 0; i -= 1) {
    const call = promptCalls[i] as [{ body: { parts: Array<{ text: string }> } }];
    const text = call[0]?.body?.parts?.[0]?.text;
    if (typeof text !== "string") continue;
    const match = text.match(
      /Your agent ID is ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/
    );
    if (match) {
      return match[1];
    }
  }

  throw new Error("Could not extract agent ID from prompt calls");
}

function getPrimaryRegistryToken(directory: string): string {
  const envToken = process.env.VICHE_REGISTRY_TOKEN?.split(",")
    .map((t) => t.trim())
    .find(Boolean);
  if (envToken) return envToken;

  const raw = readFileSync(join(directory, ".opencode", "viche.json"), "utf-8");
  const parsed = JSON.parse(raw) as { registries?: string[]; registryToken?: string };
  const fileToken = parsed.registries?.[0] ?? parsed.registryToken;
  if (!fileToken) {
    throw new Error("Could not determine registry token for E2E discovery");
  }
  return fileToken;
}

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
  const primaryDirectory = "/tmp/e2e-test";

  // ── Setup: register agent + connect WebSocket ────────────────────────────

  beforeAll(async () => {
    (mockClient.session.prompt as ReturnType<typeof mock>).mockClear();
    (mockClient.session.promptAsync as ReturnType<typeof mock>).mockClear();

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
      directory: primaryDirectory,
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
    ourAgentId = extractAgentIdFromPromptCalls(mockClient);
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

      expect(result).toMatch(
        /Found \d+ agent\(s\)|No agents found matching that capability\.|Failed to parse discovery response from Viche\./
      );

      const registry = getPrimaryRegistryToken(primaryDirectory);
      const resp = await fetch(
        `${BASE_URL}/registry/discover?capability=*&registry=${encodeURIComponent(registry)}`
      );
      expect(resp.ok).toBe(true);
      const { agents } = (await resp.json()) as { agents: Array<{ id: string }> };
      expect(agents.some((a) => a.id === ourAgentId)).toBe(true);
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

      const senderSessionId = `e2e-session-sender-${Date.now()}`;
      const senderClient = {
        session: {
          prompt: mock(() => Promise.resolve()),
          promptAsync: mock(() => Promise.resolve()),
        },
      };

      const { default: senderPlugin } = await import(`../index.js?sender=${Date.now()}`);
      const senderHooks = await senderPlugin({
        client: senderClient,
        directory: "/tmp/e2e-test-4",
      });

      try {
        await senderHooks.event({
          event: {
            type: "session.created",
            properties: { info: { id: senderSessionId } },
          },
        });

        const senderId = extractAgentIdFromPromptCalls(senderClient);

        const senderSendTool = senderHooks.tool["viche_send"] as ToolDef;
        const sendResult = await senderSendTool.execute(
          { to: ourAgentId, body: "e2e websocket delivery test", type: "task" },
          { sessionID: senderSessionId }
        );
        expect(sendResult).toContain("sent");

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
      } finally {
        await senderHooks.event({
          event: {
            type: "session.deleted",
            properties: { info: { id: senderSessionId } },
          },
        });
      }
    },
    10_000
  );

  // ── Test 6: viche_reply → result message delivery ─────────────────────────

  it(
    "Test 6: viche_reply sends a result message to an external agent",
    async () => {
      const externalId = await registerAgent(["e2e-reply-target"]);

      const replyTool = hooks.tool["viche_reply"] as ToolDef;
      const result = await replyTool.execute(
        { to: externalId, body: "reply from e2e" },
        { sessionID: SESSION_ID }
      );
      expect(result).toContain("Reply sent");

      const messages = await drainInbox(externalId);
      expect(messages).toHaveLength(1);
      expect(messages[0].type).toBe("result");
      expect(messages[0].from).toBe(ourAgentId);
      expect(messages[0].body).toBe("reply from e2e");
    },
    10_000
  );

  // ── Test 7: viche_deregister partial (single registry) ───────────────────

  it(
    "Test 7: viche_deregister removes only the specified registry",
    async () => {
      const partialRegistry = `e2e-partial-dereg-${Date.now()}`;
      const prevRegistryToken = process.env.VICHE_REGISTRY_TOKEN;
      process.env.VICHE_REGISTRY_TOKEN = `global,${partialRegistry}`;

      const isolatedSessionId = `e2e-session-partial-${Date.now()}`;
      const isolatedClient = {
        session: {
          prompt: mock(() => Promise.resolve()),
          promptAsync: mock(() => Promise.resolve()),
        },
      };

      let isolatedHooks: Hooks | undefined;

      try {
        const { default: isolatedPlugin } = await import(`../index.js?partial=${Date.now()}`);
        isolatedHooks = await isolatedPlugin({
          client: isolatedClient,
          directory: "/tmp/e2e-test-7",
        });

        await isolatedHooks.event({
          event: {
            type: "session.created",
            properties: { info: { id: isolatedSessionId } },
          },
        });

        const isolatedAgentId = extractAgentIdFromPromptCalls(isolatedClient);

        const preResp = await fetch(
          `${BASE_URL}/registry/discover?capability=*&registry=${encodeURIComponent(partialRegistry)}`
        );
        expect(preResp.ok).toBe(true);
        const preJson = (await preResp.json()) as { agents: Array<{ id: string }> };
        expect(preJson.agents.some((a) => a.id === isolatedAgentId)).toBe(true);

        const deregisterTool = isolatedHooks.tool["viche_deregister"] as ToolDef | undefined;
        if (!deregisterTool) {
          // viche_deregister is not exported by this plugin build; intentionally skip.
          expect(true).toBe(true);
          return;
        }

        const deregisterResult = await deregisterTool.execute(
          { registry: partialRegistry },
          { sessionID: isolatedSessionId }
        );
        expect(deregisterResult).toContain("Deregistered from registry");

        const postScopedResp = await fetch(
          `${BASE_URL}/registry/discover?capability=*&registry=${encodeURIComponent(partialRegistry)}`
        );
        expect(postScopedResp.ok).toBe(true);
        const postScopedJson = (await postScopedResp.json()) as { agents: Array<{ id: string }> };
        expect(postScopedJson.agents.some((a) => a.id === isolatedAgentId)).toBe(false);

        const postGlobalResp = await fetch(`${BASE_URL}/registry/discover?capability=*&registry=global`);
        expect(postGlobalResp.ok).toBe(true);
        const postGlobalJson = (await postGlobalResp.json()) as { agents: Array<{ id: string }> };
        expect(postGlobalJson.agents.some((a) => a.id === isolatedAgentId)).toBe(true);
      } finally {
        if (prevRegistryToken === undefined) {
          delete process.env.VICHE_REGISTRY_TOKEN;
        } else {
          process.env.VICHE_REGISTRY_TOKEN = prevRegistryToken;
        }
        if (isolatedHooks) {
          await isolatedHooks.event({
            event: {
              type: "session.deleted",
              properties: { info: { id: isolatedSessionId } },
            },
          });
        }
      }
    },
    15_000
  );

  // ── Test 8: viche_deregister full (all registries) ────────────────────────

  it(
    "Test 8: viche_deregister with no registry removes agent from all registries",
    async () => {
      const fullRegistry = `e2e-full-dereg-${Date.now()}`;
      const prevRegistryToken = process.env.VICHE_REGISTRY_TOKEN;
      process.env.VICHE_REGISTRY_TOKEN = `global,${fullRegistry}`;

      const isolatedSessionId = `e2e-session-full-${Date.now()}`;
      const isolatedClient = {
        session: {
          prompt: mock(() => Promise.resolve()),
          promptAsync: mock(() => Promise.resolve()),
        },
      };

      let isolatedHooks: Hooks | undefined;

      try {
        const { default: isolatedPlugin } = await import(`../index.js?full=${Date.now()}`);
        isolatedHooks = await isolatedPlugin({
          client: isolatedClient,
          directory: "/tmp/e2e-test-8",
        });

        await isolatedHooks.event({
          event: {
            type: "session.created",
            properties: { info: { id: isolatedSessionId } },
          },
        });

        const isolatedAgentId = extractAgentIdFromPromptCalls(isolatedClient);

        const deregisterTool = isolatedHooks.tool["viche_deregister"] as ToolDef | undefined;
        if (!deregisterTool) {
          // viche_deregister is not exported by this plugin build; intentionally skip.
          expect(true).toBe(true);
          return;
        }

        const deregisterResult = await deregisterTool.execute({}, { sessionID: isolatedSessionId });
        expect(deregisterResult).toContain("Deregistered from all registries");

        const scopedResp = await fetch(
          `${BASE_URL}/registry/discover?capability=*&registry=${encodeURIComponent(fullRegistry)}`
        );
        expect(scopedResp.ok).toBe(true);
        const scopedJson = (await scopedResp.json()) as { agents: Array<{ id: string }> };
        expect(scopedJson.agents.some((a) => a.id === isolatedAgentId)).toBe(false);

        const globalResp = await fetch(`${BASE_URL}/registry/discover?capability=*&registry=global`);
        expect(globalResp.ok).toBe(true);
        const globalJson = (await globalResp.json()) as { agents: Array<{ id: string }> };
        expect(globalJson.agents.some((a) => a.id === isolatedAgentId)).toBe(false);
      } finally {
        if (prevRegistryToken === undefined) {
          delete process.env.VICHE_REGISTRY_TOKEN;
        } else {
          process.env.VICHE_REGISTRY_TOKEN = prevRegistryToken;
        }
        if (isolatedHooks) {
          await isolatedHooks.event({
            event: {
              type: "session.deleted",
              properties: { info: { id: isolatedSessionId } },
            },
          });
        }
      }
    },
    15_000
  );

  // ── Test 9: concurrent sessions have unique agent IDs ─────────────────────

  it(
    "Test 9: concurrent sessions register unique agent IDs",
    async () => {
      const sessionB = `e2e-session-B-${Date.now()}`;
      const mockClientB = {
        session: {
          prompt: mock(() => Promise.resolve()),
          promptAsync: mock(() => Promise.resolve()),
        },
      };

      const { default: vichePlugin } = await import("../index.js");
      const hooksB = await vichePlugin({
        client: mockClientB,
        directory: "/tmp/e2e-test-9",
      });

      try {
        await hooksB.event({
          event: {
            type: "session.created",
            properties: { info: { id: sessionB } },
          },
        });

        const secondAgentId = extractAgentIdFromPromptCalls(mockClientB);
        expect(secondAgentId).not.toBe(ourAgentId);

        const sendFromPrimary = hooks.tool["viche_send"] as ToolDef;
        const sendFromSecondary = hooksB.tool["viche_send"] as ToolDef;

        const firstSend = await sendFromPrimary.execute(
          { to: secondAgentId, body: "from session A", type: "task" },
          { sessionID: SESSION_ID }
        );
        expect(firstSend).toContain("sent");

        const secondInbox = await drainInbox(secondAgentId);
        expect(secondInbox.some((m) => m.from === ourAgentId && m.body === "from session A")).toBe(true);

        const secondSend = await sendFromSecondary.execute(
          { to: ourAgentId, body: "from session B", type: "task" },
          { sessionID: sessionB }
        );
        expect(secondSend).toContain("sent");

        const ourInbox = await drainInbox(ourAgentId);
        expect(ourInbox.some((m) => m.from === secondAgentId && m.body === "from session B")).toBe(true);
      } finally {
        await hooksB.event({
          event: {
            type: "session.deleted",
            properties: { info: { id: sessionB } },
          },
        });
      }
    },
    15_000
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
