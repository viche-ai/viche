/**
 * Tests for channel-level reconnection recovery.
 *
 * Scenario: The Phoenix socket reconnects after a disconnect, but the agent
 * was deregistered server-side during the gap. Channel rejoin returns
 * `agent_not_found`. The plugin must:
 *   1. Detect the error via channel.onError
 *   2. Re-join `agent:register` to get a new agentId
 *   3. Tear down the old socket/channel
 *   4. Create a new socket+registered channel
 *   5. Not loop infinitely (recovering flag)
 */

import { describe, it, expect, mock, beforeEach } from "bun:test";

// ---------------------------------------------------------------------------
// Mock Phoenix module — injectable per test
// ---------------------------------------------------------------------------

type ChannelErrorCallback = (reason: unknown) => void;

const joinOkPayloads: Array<Record<string, unknown>> = [];

const makeChannelMock = () => ({
  on: mock((_event: string, _cb: unknown) => {}),
  onError: mock((_cb: ChannelErrorCallback) => {}),
  onClose: mock((_cb: () => void) => {}),
  leave: mock(() => {}),
  join: mock(() => ({
    receive: function (status: string, cb: (...args: unknown[]) => void) {
      if (status === "ok") cb(joinOkPayloads.shift() ?? { agent_id: "agent-default" });
      return this;
    },
  })),
});

type MockChannel = ReturnType<typeof makeChannelMock>;

let channelMocks: MockChannel[] = [];

const makeSocketMock = () => ({
  connect: mock(() => {}),
  disconnect: mock(() => {}),
  channel: mock((_topic: string) => {
    const ch = makeChannelMock();
    channelMocks.push(ch);
    return ch;
  }),
  onOpen: mock((_cb: () => void) => {}),
  onClose: mock((_cb: () => void) => {}),
  onError: mock((_cb: () => void) => {}),
});

type MockSocket = ReturnType<typeof makeSocketMock>;

let socketMocks: MockSocket[] = [];

mock.module("phoenix", () => ({
  Socket: class {
    constructor(_url: string, _opts: unknown) {
      const s = makeSocketMock();
      socketMocks.push(s);
      return s;
    }
  },
}));

// Import after mock.module so the mock is in place
import { createVicheService } from "./service.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const makeState = () => ({
  agentId: null as string | null,
  correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
  mostRecentSessionKey: null as string | null,
});

const makeConfig = () => ({
  registryUrl: "http://test.local",
  capabilities: ["coding"],
});

const makeRuntime = () => ({
  subagent: {
    run: mock(async (_opts: unknown) => ({ runId: "run-1" })),
  },
});

const makeLogger = () => ({
  info: mock((_msg: string) => {}),
  warn: mock((_msg: string) => {}),
  error: mock((_msg: string) => {}),
});

// Trigger the onError callback registered on a channel mock
const triggerChannelError = (ch: MockChannel, reason: unknown): void => {
  const call = ch.onError.mock.calls[0];
  if (!call) throw new Error("onError was never registered on this channel");
  const cb = call[0] as ChannelErrorCallback;
  cb(reason);
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("channel.onError recovery", () => {
  beforeEach(() => {
    joinOkPayloads.length = 0;
    channelMocks = [];
    socketMocks = [];
  });

  it("re-registers via agent:register join and creates a new socket+channel when channel.onError fires with agent_not_found", async () => {
    const state = makeState();
    const config = makeConfig();
    const runtime = makeRuntime();
    const logger = makeLogger();

    // First join: initial registration → agentId "agent-1"
    // Second join: recovery registration → agentId "agent-2"
    joinOkPayloads.push({ agent_id: "agent-1" }, { agent_id: "agent-2" });

    const service = createVicheService(config, state, runtime, {});
    await service.start({ logger } as any);

    // After start: agentId should be "agent-1"
    expect(state.agentId).toBe("agent-1");
    // One socket created, one agent channel joined
    expect(socketMocks.length).toBe(1);

    // The agent channel is the first one created by socket.channel
    const firstAgentChannel = channelMocks[0];
    expect(firstAgentChannel).toBeDefined();
    // onError must have been registered
    expect(firstAgentChannel!.onError.mock.calls.length).toBeGreaterThan(0);

    // Simulate the channel error (agent_not_found after socket reconnects)
    triggerChannelError(firstAgentChannel!, { reason: "agent_not_found" });

    // Give the async recovery a tick to run
    await new Promise((r) => setTimeout(r, 50));

    // agentId should now be the new one
    expect(state.agentId).toBe("agent-2");

    // registration channel topic is now agent:register
    expect(socketMocks[0]!.channel.mock.calls[0]?.[0]).toBe("agent:register");
    expect(socketMocks[1]!.channel.mock.calls[0]?.[0]).toBe("agent:register");

    // A second socket should have been created for the new agentId
    expect(socketMocks.length).toBe(2);

    // The old socket should have been disconnected
    expect(socketMocks[0]!.disconnect.mock.calls.length).toBeGreaterThan(0);

    // The old channel should have been told to leave
    expect(firstAgentChannel!.leave.mock.calls.length).toBeGreaterThan(0);
  });

  it("does not start a second recovery if one is already in progress", async () => {
    const state = makeState();
    const config = makeConfig();
    const runtime = makeRuntime();
    const logger = makeLogger();

    // Initial start gets agent-1. Recovery join gets agent-2.
    joinOkPayloads.push({ agent_id: "agent-1" }, { agent_id: "agent-2" });

    const service = createVicheService(config, state, runtime, {});
    await service.start({ logger } as any);

    const firstChannel = channelMocks[0]!;

    // Fire two errors rapidly — second must be a no-op
    triggerChannelError(firstChannel, { reason: "agent_not_found" });
    triggerChannelError(firstChannel, { reason: "agent_not_found" });

    // Allow async recovery to settle.
    await new Promise((r) => setTimeout(r, 50));

    // Only one recovery socket should be created despite two errors.
    expect(socketMocks.length).toBe(2);
  });

  it("stops recovery gracefully when stop() is called during re-registration", async () => {
    const state = makeState();
    const config = makeConfig();
    const runtime = makeRuntime();
    const logger = makeLogger();

    joinOkPayloads.push({ agent_id: "agent-1" }, { agent_id: "agent-2" });

    const service = createVicheService(config, state, runtime, {});
    await service.start({ logger } as any);

    const firstChannel = channelMocks[0]!;

    // Trigger error → starts slow re-registration
    triggerChannelError(firstChannel, { reason: "agent_not_found" });

    // Call stop() while re-registration is in progress
    await service.stop({ logger } as any);
    await new Promise((r) => setTimeout(r, 50));

    // Recovery may have created a new socket before stop() races in,
    // but stop must disconnect all active resources and clear shared state.
    expect(socketMocks.length).toBeGreaterThanOrEqual(1);

    const disconnectCalls = socketMocks.reduce(
      (total, s) => total + s.disconnect.mock.calls.length,
      0,
    );
    expect(disconnectCalls).toBeGreaterThan(0);

    // agentId cleared by stop()
    expect(state.agentId).toBeNull();
  });
});
