/**
 * Tests for createVicheTools — covers all three tool behaviors:
 * viche_discover, viche_send, viche_reply.
 *
 * Mock strategy:
 *   - `global.fetch`      → mocked per-test for HTTP calls
 *   - `ensureSessionReady` → mock function returning a fixed SessionState
 */

import { mock, describe, it, expect, beforeEach, afterEach } from "bun:test";
import { createVicheTools } from "../tools.js";
import type { VicheConfig, VicheState, SessionState } from "../types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeConfig(overrides?: Partial<VicheConfig>): VicheConfig {
  return {
    registryUrl: "http://localhost:4000",
    capabilities: ["coding"],
    ...overrides,
  };
}

function makeState(): VicheState {
  return {
    sessions: new Map(),
    initializing: new Map(),
  };
}

const fakeSessionState: SessionState = {
  agentId: "abc123de-0000-4000-a000-000000000000",
  socket: {},
  channel: {},
};

function makeEnsureSessionReady(sessionState = fakeSessionState) {
  return mock((_sessionID: string): Promise<SessionState> =>
    Promise.resolve(sessionState)
  );
}

/** Build a successful fetch Response with a JSON body. */
function fetchOkJson(body: unknown) {
  return mock(() =>
    Promise.resolve({
      ok: true,
      status: 200,
      statusText: "OK",
      json: () => Promise.resolve(body),
    } as Response)
  );
}

/** Build a failing fetch Response (non-ok HTTP status). */
function fetchFail(status = 404, statusText = "Not Found") {
  return mock(() =>
    Promise.resolve({
      ok: false,
      status,
      statusText,
      json: () => Promise.resolve({}),
    } as Response)
  );
}

/** Build a fetch mock that throws a network error. */
function fetchThrow(message = "fetch failed") {
  return mock((): Promise<Response> => {
    throw new Error(message);
  });
}

const TEST_SESSION_ID = "test-session-1";
const TEST_CONTEXT = { sessionID: TEST_SESSION_ID };

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe("createVicheTools", () => {
  let config: VicheConfig;
  let state: VicheState;
  let ensureSessionReady: ReturnType<typeof makeEnsureSessionReady>;

  beforeEach(() => {
    config = makeConfig();
    state = makeState();
    ensureSessionReady = makeEnsureSessionReady();
  });

  afterEach(() => {
    // Restore global fetch to avoid cross-test contamination.
    (global as unknown as Record<string, unknown>)["fetch"] = undefined;
  });

  // ── Smoke: factory returns three tools ────────────────────────────────────

  it("returns an object with viche_discover, viche_send, and viche_reply tools", () => {
    const tools = createVicheTools(config, state, ensureSessionReady);

    expect(Object.keys(tools)).toContain("viche_discover");
    expect(Object.keys(tools)).toContain("viche_send");
    expect(Object.keys(tools)).toContain("viche_reply");

    expect(typeof tools["viche_discover"]!.execute).toBe("function");
    expect(typeof tools["viche_send"]!.execute).toBe("function");
    expect(typeof tools["viche_reply"]!.execute).toBe("function");
  });

  // ── viche_discover ─────────────────────────────────────────────────────────

  describe("viche_discover", () => {
    // 1. Capability "coding" → GETs correct URL, returns formatted list
    it("GETs /registry/discover?capability=coding and returns formatted agent list", async () => {
      global.fetch = fetchOkJson({
        agents: [
          { id: "a1b2c3d4", name: "Coder", capabilities: ["coding"], description: "A coding agent" },
        ],
      });

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_discover"]!.execute(
        { capability: "coding" },
        TEST_CONTEXT
      );

      expect(global.fetch).toHaveBeenCalledTimes(1);
      const [url] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [string];
      expect(url).toBe("http://localhost:4000/registry/discover?capability=coding");

      expect(result).toContain("Found 1 agent(s):");
      expect(result).toContain("a1b2c3d4");
      expect(result).toContain("Coder");
      expect(result).toContain("coding");
      expect(result).toContain("A coding agent");
    });

    // 2. Capability "*" → GETs /registry/discover?capability=*, returns all agents
    it("GETs /registry/discover?capability=* and returns all agents", async () => {
      global.fetch = fetchOkJson({
        agents: [
          { id: "aaaaaaaa", capabilities: ["coding"] },
          { id: "bbbbbbbb", capabilities: ["research"] },
        ],
      });

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_discover"]!.execute(
        { capability: "*" },
        TEST_CONTEXT
      );

      const [url] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [string];
      expect(url).toBe("http://localhost:4000/registry/discover?capability=*");

      expect(result).toContain("Found 2 agent(s):");
      expect(result).toContain("aaaaaaaa");
      expect(result).toContain("bbbbbbbb");
    });

    // 3. No matching agents → returns "No agents found" message
    it("returns 'No agents found matching that capability.' when response has empty agents array", async () => {
      global.fetch = fetchOkJson({ agents: [] });

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_discover"]!.execute(
        { capability: "nonexistent" },
        TEST_CONTEXT
      );

      expect(result).toBe("No agents found matching that capability.");
    });

    // 4. Does NOT call ensureSessionReady (stateless HTTP GET)
    it("does NOT call ensureSessionReady — viche_discover is stateless", async () => {
      global.fetch = fetchOkJson({ agents: [] });

      const tools = createVicheTools(config, state, ensureSessionReady);
      await tools["viche_discover"]!.execute({ capability: "coding" }, TEST_CONTEXT);

      expect(ensureSessionReady).not.toHaveBeenCalled();
    });

    // 9. Registry unreachable → returns error text, does NOT throw
    it("returns error text (does not throw) when registry is unreachable", async () => {
      global.fetch = fetchThrow("ECONNREFUSED");

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_discover"]!.execute(
        { capability: "coding" },
        TEST_CONTEXT
      );

      expect(typeof result).toBe("string");
      expect(result).toContain("ECONNREFUSED");
      // Must not throw
    });

    // Formats agents with optional fields correctly
    it("formats agent entries with optional name and description omitted when absent", async () => {
      global.fetch = fetchOkJson({
        agents: [{ id: "deadbeef-0000-4000-a000-000000000000", capabilities: ["research"] }],
      });

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_discover"]!.execute(
        { capability: "research" },
        TEST_CONTEXT
      );

      expect(result).toContain("• deadbeef-0000-4000-a000-000000000000");
      expect(result).toContain("capabilities: research");
      // No name or description in the line
      expect(result).not.toContain("undefined");
    });
  });

  // ── viche_send ─────────────────────────────────────────────────────────────

  describe("viche_send", () => {
    // 4. POSTs to /messages/:to with correct from/body/type
    it("POSTs to /messages/:to with from, body, and type from session state", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_send"]!.execute(
        { to: "deadbeef-0000-4000-a000-000000000000", body: "Please review this code", type: "task" },
        TEST_CONTEXT
      );

      expect(global.fetch).toHaveBeenCalledTimes(1);
      const [url, init] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [
        string,
        RequestInit,
      ];
      expect(url).toBe("http://localhost:4000/messages/deadbeef-0000-4000-a000-000000000000");
      expect((init as RequestInit).method).toBe("POST");

      const body = JSON.parse((init as RequestInit).body as string) as {
        from: string;
        body: string;
        type: string;
      };
      expect(body.from).toBe("abc123de-0000-4000-a000-000000000000"); // from session state
      expect(body.body).toBe("Please review this code");
      expect(body.type).toBe("task");

      expect(result).toContain("Message sent to deadbeef-0000-4000-a000-000000000000");
      expect(result).toContain("type: task");
    });

    // 5. No type provided → defaults to "task"
    it("defaults message type to 'task' when type arg is omitted", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_send"]!.execute(
        { to: "deadbeef-0000-4000-a000-000000000000", body: "Hello" },
        TEST_CONTEXT
      );

      const [, init] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [
        string,
        RequestInit,
      ];
      const body = JSON.parse((init as RequestInit).body as string) as { type: string };
      expect(body.type).toBe("task");
      expect(result).toContain("type: task");
    });

    // 6. type "ping" → type is "ping" in POST body
    it("uses provided type 'ping' in POST body", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      await tools["viche_send"]!.execute(
        { to: "deadbeef-0000-4000-a000-000000000000", body: "ping", type: "ping" },
        TEST_CONTEXT
      );

      const [, init] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [
        string,
        RequestInit,
      ];
      const body = JSON.parse((init as RequestInit).body as string) as { type: string };
      expect(body.type).toBe("ping");
    });

    // 8. Calls ensureSessionReady before POSTing
    it("calls ensureSessionReady with the session ID before posting", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      await tools["viche_send"]!.execute(
        { to: "deadbeef-0000-4000-a000-000000000000", body: "Hello" },
        TEST_CONTEXT
      );

      expect(ensureSessionReady).toHaveBeenCalledTimes(1);
      expect(ensureSessionReady).toHaveBeenCalledWith(TEST_SESSION_ID);
    });

    // 10. HTTP 404 response → returns error text, does NOT throw
    it("returns error text (does not throw) when server returns 404", async () => {
      global.fetch = fetchFail(404, "Not Found");

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_send"]!.execute(
        { to: "unknown-agent", body: "Hello" },
        TEST_CONTEXT
      );

      expect(typeof result).toBe("string");
      expect(result).toContain("404");
      // Must not throw
    });
  });

  // ── viche_reply ────────────────────────────────────────────────────────────

  describe("viche_reply", () => {
    // 7. POSTs to /messages/:to with type "result"
    it("POSTs to /messages/:to with type 'result' and returns reply confirmation", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_reply"]!.execute(
        { to: "cafebabe-0000-4000-a000-000000000000", body: "Task complete" },
        TEST_CONTEXT
      );

      expect(global.fetch).toHaveBeenCalledTimes(1);
      const [url, init] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [
        string,
        RequestInit,
      ];
      expect(url).toBe("http://localhost:4000/messages/cafebabe-0000-4000-a000-000000000000");
      expect((init as RequestInit).method).toBe("POST");

      const body = JSON.parse((init as RequestInit).body as string) as {
        from: string;
        body: string;
        type: string;
      };
      expect(body.from).toBe("abc123de-0000-4000-a000-000000000000"); // from session state
      expect(body.body).toBe("Task complete");
      expect(body.type).toBe("result");

      expect(result).toContain("Reply sent to cafebabe-0000-4000-a000-000000000000");
    });

    // Calls ensureSessionReady before sending reply
    it("calls ensureSessionReady with the session ID before posting reply", async () => {
      global.fetch = fetchOkJson({});

      const tools = createVicheTools(config, state, ensureSessionReady);
      await tools["viche_reply"]!.execute(
        { to: "cafebabe-0000-4000-a000-000000000000", body: "Done" },
        TEST_CONTEXT
      );

      expect(ensureSessionReady).toHaveBeenCalledTimes(1);
      expect(ensureSessionReady).toHaveBeenCalledWith(TEST_SESSION_ID);
    });

    // Network error in reply → returns error text, does NOT throw
    it("returns error text (does not throw) when network fails during reply", async () => {
      global.fetch = fetchThrow("Network unreachable");

      const tools = createVicheTools(config, state, ensureSessionReady);
      const result = await tools["viche_reply"]!.execute(
        { to: "cafebabe-0000-4000-a000-000000000000", body: "Done" },
        TEST_CONTEXT
      );

      expect(typeof result).toBe("string");
      expect(result).toContain("Network unreachable");
    });
  });

  // ── Tool metadata ──────────────────────────────────────────────────────────

  describe("tool metadata", () => {
    it("each tool has a non-empty description string", () => {
      const tools = createVicheTools(config, state, ensureSessionReady);

      expect(typeof tools["viche_discover"]!.description).toBe("string");
      expect(tools["viche_discover"]!.description.length).toBeGreaterThan(0);

      expect(typeof tools["viche_send"]!.description).toBe("string");
      expect(tools["viche_send"]!.description.length).toBeGreaterThan(0);

      expect(typeof tools["viche_reply"]!.description).toBe("string");
      expect(tools["viche_reply"]!.description.length).toBeGreaterThan(0);
    });

    it("each tool has an args object whose values are Zod schemas", () => {
      const tools = createVicheTools(config, state, ensureSessionReady);

      for (const [name, tool] of Object.entries(tools)) {
        expect(
          typeof tool.args,
          `${name} args should be an object`
        ).toBe("object");
        expect(
          Object.keys(tool.args).length,
          `${name} args should have at least one field`
        ).toBeGreaterThan(0);
        // Each value in args should be a Zod type (has a _zod.def property in Zod v4)
        for (const [fieldName, zodType] of Object.entries(tool.args)) {
          expect(
            (zodType as { _zod?: { def?: unknown } })._zod?.def,
            `${name}.args.${fieldName} should be a Zod schema`
          ).toBeDefined();
        }
      }
    });
  });
});
