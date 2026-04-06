/**
 * Tests for createVicheService — covers session lifecycle, WebSocket register-on-join,
 * message injection, deduplication, and retry behavior.
 */

import { mock, describe, it, expect, beforeEach } from "bun:test";
import type { VicheConfig, VicheState, SessionState } from "../types.js";

type JoinOutcome = {
  event: "ok" | "error" | "timeout";
  payload?: unknown;
  delayMs?: number;
};

let _onHandlers: Record<string, (...args: unknown[]) => void> = {};
let _channelErrorHandler: ((reason: unknown) => void) | null = null;
let joinOutcomes: JoinOutcome[] = [];

function makeJoinSequence() {
  let callIndex = 0;
  return () => {
    const cbs: Record<string, (...args: unknown[]) => void> = {};
    const push = {
      receive(event: string, cb: (...args: unknown[]) => void) {
        cbs[event] = cb;
        return push;
      },
    };

    const outcome =
      joinOutcomes[callIndex++] ?? {
        event: "ok" as const,
        payload: { agent_id: "abc12345-0000-4000-a000-000000000000" },
        delayMs: 5,
      };

    setTimeout(() => {
      if (outcome.event === "ok") cbs["ok"]?.(outcome.payload ?? {});
      if (outcome.event === "error") cbs["error"]?.(outcome.payload ?? { reason: "join_failed" });
      if (outcome.event === "timeout") cbs["timeout"]?.();
    }, outcome.delayMs ?? 5);

    return push;
  };
}

const mockChannel = {
  join: mock(makeJoinSequence()),
  on: mock((event: string, cb: (...args: unknown[]) => void) => {
    _onHandlers[event] = cb;
  }),
  onError: mock((cb: (reason: unknown) => void) => {
    _channelErrorHandler = cb;
  }),
  leave: mock(() => {}),
};

const mockSocketMethods = {
  connect: mock(() => {}),
  disconnect: mock(() => {}),
  onOpen: mock((_cb: () => void) => {}),
  onClose: mock((_cb: () => void) => {}),
  channel: mock((_topic: string, _params: unknown) => mockChannel),
};

const socketConstructorArgs: Array<[string, unknown?]> = [];

class MockSocket {
  connect = mockSocketMethods.connect;
  disconnect = mockSocketMethods.disconnect;
  onOpen = mockSocketMethods.onOpen;
  onClose = mockSocketMethods.onClose;
  channel = mockSocketMethods.channel;

  constructor(url: string, opts?: unknown) {
    socketConstructorArgs.push([url, opts]);
  }
}

mock.module("phoenix", () => ({ Socket: MockSocket }));

const { createVicheService } = await import("../service.js");

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

describe("createVicheService", () => {
  let config: VicheConfig;
  let state: VicheState;
  let client: ReturnType<typeof makeClient>;

  beforeEach(() => {
    config = makeConfig();
    state = makeState();
    client = makeClient();

    _onHandlers = {};
    _channelErrorHandler = null;
    joinOutcomes = [];
    socketConstructorArgs.length = 0;

    mockChannel.join.mockReset();
    mockChannel.join.mockImplementation(makeJoinSequence());
    mockChannel.on.mockReset();
    mockChannel.on.mockImplementation((event: string, cb: (...args: unknown[]) => void) => {
      _onHandlers[event] = cb;
    });
    mockChannel.onError.mockReset();
    mockChannel.onError.mockImplementation((cb: (reason: unknown) => void) => {
      _channelErrorHandler = cb;
    });
    mockChannel.leave.mockReset();

    mockSocketMethods.connect.mockReset();
    mockSocketMethods.disconnect.mockReset();
    mockSocketMethods.onOpen.mockReset();
    mockSocketMethods.onClose.mockReset();
    mockSocketMethods.channel.mockReset();
    mockSocketMethods.channel.mockImplementation(
      (_topic: string, _params: unknown) => mockChannel
    );
  });

  it("registers by joining agent:register with config params", async () => {
    joinOutcomes = [
      {
        event: "ok",
        payload: { agent_id: "abc12345-0000-4000-a000-000000000000" },
      },
    ];

    const service = createVicheService(config, state, client, "/project");
    const session = await service.ensureSessionReady("sess-1");

    expect(session.agentId).toBe("abc12345-0000-4000-a000-000000000000");
    const [, registerPayload] = mockSocketMethods.channel.mock.calls[0] as [
      string,
      Record<string, unknown>,
    ];
    expect(registerPayload).toEqual({
      capabilities: ["coding"],
    });
    expect(Object.prototype.hasOwnProperty.call(registerPayload, "name")).toBe(
      false
    );
    expect(
      Object.prototype.hasOwnProperty.call(registerPayload, "description")
    ).toBe(false);
    expect(
      Object.prototype.hasOwnProperty.call(registerPayload, "registries")
    ).toBe(false);
  });

  it("returns existing session from state without re-registering", async () => {
    const service = createVicheService(config, state, client, "/project");
    const first = await service.ensureSessionReady("sess-1");
    const joinCallCount = mockChannel.join.mock.calls.length;

    const second = await service.ensureSessionReady("sess-1");

    expect(second).toBe(first);
    expect(mockChannel.join.mock.calls.length).toBe(joinCallCount);
  });

  it("deduplicates concurrent ensureSessionReady calls for the same session", async () => {
    const service = createVicheService(config, state, client, "/project");

    const [a, b] = await Promise.all([
      service.ensureSessionReady("sess-concurrent"),
      service.ensureSessionReady("sess-concurrent"),
    ]);

    expect(a).toBe(b);
    expect(mockChannel.join.mock.calls.length).toBe(1);
  });

  it("connects WebSocket using /agent/websocket without agent_id params", async () => {
    const service = createVicheService(config, state, client, "/project");
    await service.ensureSessionReady("sess-2");

    expect(mockSocketMethods.connect).toHaveBeenCalledTimes(1);
    const [wsUrl, opts] = socketConstructorArgs[0]!;
    expect(wsUrl).toBe("ws://localhost:4000/agent/websocket");
    expect(typeof opts).toBe("object");
    const reconnectAfterMs =
      (opts as { reconnectAfterMs?: (tries: number) => number }).reconnectAfterMs;
    expect(reconnectAfterMs?.(1)).toBe(1000);
    expect(reconnectAfterMs?.(2)).toBe(2000);
    expect(reconnectAfterMs?.(3)).toBe(5000);
    expect(reconnectAfterMs?.(4)).toBe(10000);
    expect(reconnectAfterMs?.(99)).toBe(10000);
  });

  it("re-registers session after channel error and updates agentId", async () => {
    joinOutcomes = [
      {
        event: "ok",
        payload: { agent_id: "first-0000-4000-a000-000000000000" },
      },
      {
        event: "ok",
        payload: { agent_id: "second-0000-4000-a000-000000000000" },
      },
    ];

    const service = createVicheService(config, state, client, "/project", { backoffMs: 0 });
    const session = await service.ensureSessionReady("sess-reconnect");
    expect(session.agentId).toBe("first-0000-4000-a000-000000000000");
    expect(mockChannel.join.mock.calls.length).toBe(1);

    _channelErrorHandler?.({ reason: "agent_not_found" });
    await new Promise((resolve) => setTimeout(resolve, 25));

    expect(mockChannel.join.mock.calls.length).toBe(2);
    expect(state.sessions.get("sess-reconnect")?.agentId).toBe(
      "second-0000-4000-a000-000000000000"
    );
    expect(mockSocketMethods.disconnect).toHaveBeenCalledTimes(1);
  });

  it("injects identity context via client.session.prompt with noReply: true", async () => {
    const service = createVicheService(config, state, client, "/project");
    await service.handleSessionCreated("sess-3");

    expect(client.session.prompt).toHaveBeenCalledTimes(1);
    const [callArgs] = (client.session.prompt as ReturnType<typeof mock>).mock.calls;
    const args = callArgs as [{ path: { id: string }; body: { noReply: boolean; parts: Array<{ type: string; text: string }> }; query: { directory: string } }];
    expect(args[0].path.id).toBe("sess-3");
    expect(args[0].body.noReply).toBe(true);
    expect(args[0].body.parts[0]?.type).toBe("text");
    expect(args[0].body.parts[0]?.text).toContain("abc12345-0000-4000-a000-000000000000");
    expect(args[0].query.directory).toBe("/project");
  });

  it("injects inbound task message via client.session.promptAsync", async () => {
    const service = createVicheService(config, state, client, "/project");
    await service.ensureSessionReady("sess-4");

    const payload = {
      id: "msg-001",
      from: "other-agent",
      body: "Please review this PR",
      type: "task",
    };
    await _onHandlers["new_message"]!(payload);

    expect(client.session.promptAsync).toHaveBeenCalledTimes(1);
    const [callArgs] = (client.session.promptAsync as ReturnType<typeof mock>).mock.calls;
    const args = callArgs as [{ path: { id: string }; body: { noReply: boolean; parts: Array<{ type: string; text: string }> } }];
    expect(args[0].path.id).toBe("sess-4");
    expect(args[0].body.noReply).toBe(false);
    expect(args[0].body.parts[0]?.text).toContain("[Viche Task from other-agent]");
    expect(args[0].body.parts[0]?.text).toContain("Please review this PR");
  });

  it("injects inbound result message via client.session.promptAsync", async () => {
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
    expect(args[0].body.noReply).toBe(false);
    expect(args[0].body.parts[0]?.text).toContain("[Viche Result from worker-agent]");
  });

  it("cleans up channel, socket, and state on session deleted", async () => {
    const service = createVicheService(config, state, client, "/project");
    await service.ensureSessionReady("sess-6");
    expect(state.sessions.has("sess-6")).toBe(true);

    service.handleSessionDeleted("sess-6");

    expect(mockChannel.leave).toHaveBeenCalledTimes(1);
    expect(mockSocketMethods.disconnect).toHaveBeenCalledTimes(1);
    expect(state.sessions.has("sess-6")).toBe(false);
  });

  it("throws after 3 failed join attempts", async () => {
    joinOutcomes = [
      { event: "error", payload: { reason: "boom-1" } },
      { event: "error", payload: { reason: "boom-2" } },
      { event: "error", payload: { reason: "boom-3" } },
    ];

    const service = createVicheService(config, state, client, "/project", { backoffMs: 0 });

    await expect(service.ensureSessionReady("sess-retry")).rejects.toThrow(
      /registration failed after 3 attempts/i
    );
    expect(mockChannel.join.mock.calls.length).toBe(3);
  });

  it("retries join and succeeds on a later attempt", async () => {
    joinOutcomes = [
      { event: "error", payload: { reason: "transient" } },
      {
        event: "ok",
        payload: { agent_id: "a1b2c3d4-0000-4000-a000-000000000002" },
      },
    ];

    const service = createVicheService(config, state, client, "/project", { backoffMs: 0 });
    const session = await service.ensureSessionReady("sess-recovery");

    expect(mockChannel.join.mock.calls.length).toBe(2);
    expect(session.agentId).toBe("a1b2c3d4-0000-4000-a000-000000000002");
  });

  it("shuts down all active sessions on shutdown()", async () => {
    mockChannel.leave.mockReset();
    mockSocketMethods.disconnect.mockReset();

    const service = createVicheService(config, state, client, "/project");
    await service.ensureSessionReady("sess-a");
    await service.ensureSessionReady("sess-b");
    expect(state.sessions.size).toBe(2);

    service.shutdown();
    expect(state.sessions.size).toBe(0);
  });

  it("handleSessionDeleted is a no-op for unknown session IDs", () => {
    const service = createVicheService(config, state, client, "/project");

    expect(() => service.handleSessionDeleted("nonexistent")).not.toThrow();
    expect(mockChannel.leave).not.toHaveBeenCalled();
    expect(mockSocketMethods.disconnect).not.toHaveBeenCalled();
  });
});
