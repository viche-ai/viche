/**
 * Tests for createVicheService — covers session lifecycle, agent registration,
 * WebSocket connection, message injection, deduplication, and error recovery.
 *
 * Mock strategy:
 *   - `global.fetch`      → mocked per-test for HTTP registration calls
 *   - `phoenix` module    → mocked via mock.module (must precede dynamic import)
 *   - `client.session.*`  → plain mock functions per test
 */

import { mock, describe, it, expect, beforeEach, afterEach } from "bun:test";
import type { VicheConfig, VicheState, SessionState } from "../types.js";

// ── Phoenix mock ─────────────────────────────────────────────────────────────

// Mutable state that tests can inspect / manipulate per test.
let _onHandlers: Record<string, (...args: unknown[]) => void> = {};
let _joinTrigger: ((outcome: "ok" | "error", reason?: string) => void) | null =
  null;

/** Factory that returns a join() impl triggering `outcome` after `delayMs`. */
function makeJoin(outcome: "ok" | "error" = "ok", reason?: string, delayMs = 5) {
  return () => {
    const cbs: Record<string, (...args: unknown[]) => void> = {};
    const push = {
      receive(event: string, cb: (...args: unknown[]) => void) {
        cbs[event] = cb;
        // Expose a trigger so tests can fire the callback manually.
        _joinTrigger = (o: "ok" | "error", r?: string) => {
          if (o === "ok") cbs["ok"]?.({});
          else cbs["error"]?.({ reason: r ?? reason });
        };
        return push;
      },
    };
    if (delayMs >= 0) {
      setTimeout(() => {
        if (outcome === "ok") cbs["ok"]?.({});
        else cbs["error"]?.({ reason });
      }, delayMs);
    }
    return push;
  };
}

// We keep a single mutable channel/socket that we reconfigure in beforeEach.
const mockChannel = {
  join: mock(makeJoin("ok")),
  on: mock((event: string, cb: (...args: unknown[]) => void) => {
    _onHandlers[event] = cb;
  }),
  leave: mock(() => {}),
};

const mockSocketMethods = {
  connect: mock(() => {}),
  disconnect: mock(() => {}),
  channel: mock((_topic: string, _params: unknown) => mockChannel),
};

/** Tracks all Socket instances created; tests can assert on constructor args. */
const socketConstructorArgs: Array<[string, unknown]> = [];

class MockSocket {
  connect = mockSocketMethods.connect;
  disconnect = mockSocketMethods.disconnect;
  channel = mockSocketMethods.channel;

  constructor(url: string, opts: unknown) {
    socketConstructorArgs.push([url, opts]);
  }
}

// Hook phoenix BEFORE the dynamic import below.
mock.module("phoenix", () => ({ Socket: MockSocket }));

// Dynamic import so the phoenix mock is in place when service.ts loads.
const { createVicheService } = await import("../service.js");

// ── Helpers ───────────────────────────────────────────────────────────────────

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

function makeClient() {
  return {
    session: {
      prompt: mock(() => Promise.resolve({})),
      promptAsync: mock(() => Promise.resolve({})),
    },
  };
}

/** Make a fetch mock that always resolves successfully with the given agentId. */
function fetchOk(agentId: string) {
  return mock(() =>
    Promise.resolve({
      ok: true,
      status: 200,
      statusText: "OK",
      json: () => Promise.resolve({ id: agentId }),
    } as Response)
  );
}

/** Make a fetch mock that always returns a server error. */
function fetchFail() {
  return mock(() =>
    Promise.resolve({
      ok: false,
      status: 500,
      statusText: "Internal Server Error",
      json: () => Promise.resolve({}),
    } as Response)
  );
}

// ── Suite ─────────────────────────────────────────────────────────────────────

describe("createVicheService", () => {
  let config: VicheConfig;
  let state: VicheState;
  let client: ReturnType<typeof makeClient>;

  beforeEach(() => {
    config = makeConfig();
    state = makeState();
    client = makeClient();

    // Reset shared mutable mock state.
    _onHandlers = {};
    _joinTrigger = null;
    socketConstructorArgs.length = 0;

    // Reset mock call counts and implementations.
    mockChannel.join.mockReset();
    mockChannel.join.mockImplementation(makeJoin("ok"));
    mockChannel.on.mockReset();
    mockChannel.on.mockImplementation((event: string, cb: (...args: unknown[]) => void) => {
      _onHandlers[event] = cb;
    });
    mockChannel.leave.mockReset();
    mockSocketMethods.connect.mockReset();
    mockSocketMethods.disconnect.mockReset();
    mockSocketMethods.channel.mockReset();
    mockSocketMethods.channel.mockImplementation(
      (_topic: string, _params: unknown) => mockChannel
    );
  });

  afterEach(() => {
    // Restore global fetch to avoid cross-test contamination.
    (global as unknown as Record<string, unknown>)["fetch"] = undefined;
  });

  // ── 1. New session → registers agent via HTTP POST ─────────────────────────

  it("registers a new agent via HTTP POST to /registry/register", async () => {
    global.fetch = fetchOk("abc12345-0000-4000-a000-000000000000");
    const service = createVicheService(config, state, client, "/project");

    const session = await service.ensureSessionReady("sess-1");

    expect(global.fetch).toHaveBeenCalledTimes(1);

    const [url, reqInit] = (global.fetch as ReturnType<typeof mock>).mock.calls[0] as [
      string,
      RequestInit,
    ];
    expect(url).toBe("http://localhost:4000/registry/register");
    expect((reqInit as RequestInit).method).toBe("POST");

    const body = JSON.parse((reqInit as RequestInit).body as string) as unknown;
    expect(body).toMatchObject({ capabilities: ["coding"] });

    expect(session.agentId).toBe("abc12345-0000-4000-a000-000000000000");
  });

  // ── 2. Session already in state → returns existing without re-registering ──

  it("returns existing session from state without re-registering", async () => {
    global.fetch = fetchOk("existing-agent");
    const service = createVicheService(config, state, client, "/project");

    const first = await service.ensureSessionReady("sess-1");
    const fetchCallCount = (global.fetch as ReturnType<typeof mock>).mock.calls.length;

    // Second call should reuse the stored session.
    const second = await service.ensureSessionReady("sess-1");

    expect(second).toBe(first); // same reference
    expect((global.fetch as ReturnType<typeof mock>).mock.calls.length).toBe(
      fetchCallCount
    ); // no extra fetch
  });

  // ── 3. Concurrent calls → only one registration (in-flight dedup) ──────────

  it("deduplicates concurrent ensureSessionReady calls for the same session", async () => {
    global.fetch = fetchOk("dedup-agent");
    const service = createVicheService(config, state, client, "/project");

    // Fire two concurrent calls without awaiting.
    const [a, b] = await Promise.all([
      service.ensureSessionReady("sess-concurrent"),
      service.ensureSessionReady("sess-concurrent"),
    ]);

    expect(a).toBe(b); // same session state object
    expect((global.fetch as ReturnType<typeof mock>).mock.calls.length).toBe(1); // single fetch
  });

  // ── 4. Successful registration → WebSocket joins agent:{agentId} topic ──────

  it("connects WebSocket and joins the agent:{agentId} channel topic", async () => {
    global.fetch = fetchOk("a1b2c3d4-0000-4000-a000-000000000001");
    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-2");

    expect(mockSocketMethods.connect).toHaveBeenCalledTimes(1);
    expect(mockSocketMethods.channel).toHaveBeenCalledWith("agent:a1b2c3d4-0000-4000-a000-000000000001", {});
    expect(mockChannel.join).toHaveBeenCalledTimes(1);

    // Verify the WebSocket URL uses ws:// scheme and the correct Phoenix socket path.
    // Phoenix JS appends the transport suffix ("/websocket") to this endpoint,
    // so the server receives the connection at "/agent/websocket/websocket".
    const [wsUrl] = socketConstructorArgs[0]!;
    expect(wsUrl).toBe("ws://localhost:4000/agent/websocket");
  });

  // ── 5. session.created → identity context injected with noReply: true ───────

  it("injects identity context via client.session.prompt with noReply: true on session created", async () => {
    global.fetch = fetchOk("identity-agent");
    const service = createVicheService(config, state, client, "/project");

    await service.handleSessionCreated("sess-3");

    expect(client.session.prompt).toHaveBeenCalledTimes(1);
    const [callArgs] = (client.session.prompt as ReturnType<typeof mock>).mock.calls;
    const args = callArgs as [{ path: { id: string }; body: { noReply: boolean; parts: Array<{ type: string; text: string }> }; query: { directory: string } }];
    expect(args[0].path.id).toBe("sess-3");
    expect(args[0].body.noReply).toBe(true);
    expect(args[0].body.parts[0]?.type).toBe("text");
    expect(args[0].body.parts[0]?.text).toContain("identity-agent");
    expect(args[0].query.directory).toBe("/project");
  });

  // ── 6. Inbound task message → promptAsync with noReply: false ───────────────

  it("injects inbound task message via client.session.promptAsync with noReply: false", async () => {
    global.fetch = fetchOk("inbound-agent");
    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-4");

    // Simulate an inbound "task" message over the channel.
    const payload = {
      id: "msg-001",
      from: "other-agent",
      body: "Please review this PR",
      type: "task",
    };
    await _onHandlers["new_message"]!(payload);

    expect(client.session.promptAsync).toHaveBeenCalledTimes(1);
    const [callArgs] = (client.session.promptAsync as ReturnType<typeof mock>).mock.calls;
    const args = callArgs as [{ path: { id: string }; body: { noReply: boolean; parts: Array<{ type: string; text: string }> }; query: { directory: string } }];
    expect(args[0].path.id).toBe("sess-4");
    expect(args[0].body.noReply).toBe(false);
    expect(args[0].body.parts[0]?.text).toContain("[Viche Task from other-agent]");
    expect(args[0].body.parts[0]?.text).toContain("Please review this PR");
  });

  // ── 7. Inbound result message → promptAsync with noReply: true ───────────────

  it("injects inbound result message via client.session.promptAsync with noReply: true", async () => {
    global.fetch = fetchOk("result-agent");
    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-5");

    const payload = {
      id: "msg-002",
      from: "worker-agent",
      body: "Task complete: refactoring done",
      type: "result",
    };
    await _onHandlers["new_message"]!(payload);

    expect(client.session.promptAsync).toHaveBeenCalledTimes(1);
    const [callArgs] = (client.session.promptAsync as ReturnType<typeof mock>).mock.calls;
    const args = callArgs as [{ body: { noReply: boolean; parts: Array<{ text: string }> } }];
    expect(args[0].body.noReply).toBe(true);
    expect(args[0].body.parts[0]?.text).toContain("[Viche Result from worker-agent]");
  });

  // ── 8. session.deleted → channel left, socket disconnected, state cleared ───

  it("cleans up channel, socket, and state on session deleted", async () => {
    global.fetch = fetchOk("cleanup-agent");
    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-6");
    expect(state.sessions.has("sess-6")).toBe(true);

    service.handleSessionDeleted("sess-6");

    expect(mockChannel.leave).toHaveBeenCalledTimes(1);
    expect(mockSocketMethods.disconnect).toHaveBeenCalledTimes(1);
    expect(state.sessions.has("sess-6")).toBe(false);
  });

  // ── 9. Registration fails after 3 attempts → throws error ───────────────────

  it("throws after 3 failed registration attempts without exiting the process", async () => {
    // Make fetch always fail; use backoffMs=0 to skip real delays.
    global.fetch = fetchFail();

    const service = createVicheService(config, state, client, "/project", { backoffMs: 0 });

    await expect(service.ensureSessionReady("sess-retry")).rejects.toThrow(
      /registration failed after 3 attempts/i
    );

    // Verify it made exactly 3 attempts.
    expect((global.fetch as ReturnType<typeof mock>).mock.calls.length).toBe(3);
  });

  // ── 10. agent_not_found → re-registers once and retries connection ───────────

  it("re-registers and retries WebSocket connection on agent_not_found error", async () => {
    // First call: agent_not_found; second call (re-register): new agent, ok join.
    const attemptUuids = [
      "a1b2c3d4-0000-4000-a000-000000000001",
      "a1b2c3d4-0000-4000-a000-000000000002",
    ];
    let fetchCallCount = 0;
    global.fetch = mock(() => {
      const uuid = attemptUuids[fetchCallCount]!;
      fetchCallCount++;
      return Promise.resolve({
        ok: true,
        status: 200,
        statusText: "OK",
        json: () => Promise.resolve({ id: uuid }),
      } as Response);
    });

    // First join: "agent_not_found"; second join: "ok".
    let joinCallCount = 0;
    mockChannel.join.mockImplementation(() => {
      joinCallCount++;
      const currentJoin = joinCallCount;
      const cbs: Record<string, (...args: unknown[]) => void> = {};
      const push = {
        receive(event: string, cb: (...args: unknown[]) => void) {
          cbs[event] = cb;
          return push;
        },
      };
      setTimeout(() => {
        if (currentJoin === 1) {
          cbs["error"]?.({ reason: "agent_not_found" });
        } else {
          cbs["ok"]?.({});
        }
      }, 5);
      return push;
    });

    const service = createVicheService(config, state, client, "/project");
    const session = await service.ensureSessionReady("sess-recovery");

    // Should have registered twice (original + re-register).
    expect(fetchCallCount).toBe(2);
    // Should have joined twice (original failed + retry succeeded).
    expect(joinCallCount).toBe(2);
    // Session should use the second agent ID.
    expect(session.agentId).toBe("a1b2c3d4-0000-4000-a000-000000000002");
  });

  // ── 11. shutdown() cleans up all active sessions ────────────────────────────

  it("shuts down all active sessions on shutdown()", async () => {
    global.fetch = fetchOk("multi-agent");
    // Reset call count tracking on leave/disconnect.
    mockChannel.leave.mockReset();
    mockSocketMethods.disconnect.mockReset();

    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-a");
    await service.ensureSessionReady("sess-b");
    // For the second session we need a fresh socket/channel mock.
    // Both sessions share the same mock channel/socket, which is fine —
    // we just want to confirm state is cleared for both.
    expect(state.sessions.size).toBe(2);

    service.shutdown();

    expect(state.sessions.size).toBe(0);
  });

  // ── 12. handleSessionDeleted is a no-op for unknown sessions ────────────────

  it("handleSessionDeleted is a no-op for unknown session IDs", () => {
    const service = createVicheService(config, state, client, "/project");

    // Should not throw.
    expect(() => service.handleSessionDeleted("nonexistent")).not.toThrow();
    expect(mockChannel.leave).not.toHaveBeenCalled();
    expect(mockSocketMethods.disconnect).not.toHaveBeenCalled();
  });

  // ── 13. WebSocket params include agent_id ────────────────────────────────────

  it("passes agent_id as WebSocket params", async () => {
    global.fetch = fetchOk("param-check-agent");
    const service = createVicheService(config, state, client, "/project");

    await service.ensureSessionReady("sess-params");

    const [, opts] = socketConstructorArgs[0]!;
    expect((opts as { params: { agent_id: string } }).params.agent_id).toBe(
      "param-check-agent"
    );
  });
});
