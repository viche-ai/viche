/**
 * Tests for channel-level reconnection recovery.
 *
 * Scenario: The Phoenix socket reconnects after a disconnect, but the agent
 * was deregistered server-side during the gap. Channel rejoin returns
 * `agent_not_found`. The plugin must:
 *   1. Detect the error via channel.onError
 *   2. Re-register (HTTP POST) to get a new agentId
 *   3. Tear down the old socket/channel
 *   4. Create a new socket+channel with the new agentId
 *   5. Not loop infinitely (recovering flag)
 */

import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";

// ---------------------------------------------------------------------------
// Mock Phoenix module — injectable per test
// ---------------------------------------------------------------------------

type ChannelErrorCallback = (reason: unknown) => void;

const makeChannelMock = () => ({
  on: mock((_event: string, _cb: unknown) => {}),
  onError: mock((_cb: ChannelErrorCallback) => {}),
  onClose: mock((_cb: () => void) => {}),
  leave: mock(() => {}),
  join: mock(() => ({
    receive: function (status: string, cb: (...args: unknown[]) => void) {
      if (status === "ok") cb();
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
  let originalFetch: typeof fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    channelMocks = [];
    socketMocks = [];
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("re-registers and creates a new socket+channel when channel.onError fires with agent_not_found", async () => {
    const state = makeState();
    const config = makeConfig();
    const runtime = makeRuntime();
    const logger = makeLogger();

    let fetchCallCount = 0;
    globalThis.fetch = mock(async (_url: string | URL | Request) => {
      fetchCallCount++;
      // First call: initial registration → agentId "agent-1"
      // Second call: re-registration after error → agentId "agent-2"
      const id = fetchCallCount === 1 ? "agent-1" : "agent-2";
      return new Response(JSON.stringify({ id }), { status: 200 });
    });

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

    // Expect re-registration: fetchCallCount should be 2
    expect(fetchCallCount).toBe(2);

    // agentId should now be the new one
    expect(state.agentId).toBe("agent-2");

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

    let fetchCallCount = 0;
    let resolveSecondRegistration!: () => void;
    const secondRegistrationPending = new Promise<void>(
      (res) => (resolveSecondRegistration = res),
    );

    globalThis.fetch = mock(async (_url: string | URL | Request) => {
      fetchCallCount++;
      if (fetchCallCount === 1) {
        return new Response(JSON.stringify({ id: "agent-1" }), { status: 200 });
      }
      // Block the second registration to simulate slow re-registration
      await secondRegistrationPending;
      return new Response(JSON.stringify({ id: "agent-2" }), { status: 200 });
    });

    const service = createVicheService(config, state, runtime, {});
    await service.start({ logger } as any);

    const firstChannel = channelMocks[0]!;

    // Fire two errors rapidly — second must be a no-op
    triggerChannelError(firstChannel, { reason: "agent_not_found" });
    triggerChannelError(firstChannel, { reason: "agent_not_found" });

    // Unblock the registration
    resolveSecondRegistration();
    await new Promise((r) => setTimeout(r, 50));

    // Only 2 fetch calls total (1 initial + 1 re-register), not 3
    expect(fetchCallCount).toBe(2);
  });

  it("stops recovery gracefully when stop() is called during re-registration", async () => {
    const state = makeState();
    const config = makeConfig();
    const runtime = makeRuntime();
    const logger = makeLogger();

    let resolveReRegistration!: () => void;
    const reRegistrationPending = new Promise<void>(
      (res) => (resolveReRegistration = res),
    );

    let fetchCallCount = 0;
    globalThis.fetch = mock(async (_url: string | URL | Request) => {
      fetchCallCount++;
      if (fetchCallCount === 1) {
        return new Response(JSON.stringify({ id: "agent-1" }), { status: 200 });
      }
      await reRegistrationPending;
      return new Response(JSON.stringify({ id: "agent-2" }), { status: 200 });
    });

    const service = createVicheService(config, state, runtime, {});
    await service.start({ logger } as any);

    const firstChannel = channelMocks[0]!;

    // Trigger error → starts slow re-registration
    triggerChannelError(firstChannel, { reason: "agent_not_found" });

    // Call stop() while re-registration is in progress
    await service.stop({ logger } as any);

    // Now unblock the re-registration
    resolveReRegistration();
    await new Promise((r) => setTimeout(r, 50));

    // After stop + unblocked registration: should NOT create a new socket
    // (recovery should have aborted after noticing stopped=true)
    expect(socketMocks.length).toBe(1);

    // agentId cleared by stop()
    expect(state.agentId).toBeNull();
  });
});
