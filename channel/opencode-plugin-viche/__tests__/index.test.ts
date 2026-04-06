/**
 * Integration tests for the opencode-plugin-viche entry point (index.ts).
 *
 * Tests the plugin's observable behavior without mocking local modules (which
 * would leak across test files). Instead:
 *   - `phoenix` is mocked (external dep, already mocked by service.test.ts in
 *     its own context — safe to mock here too since external packages are OK).
 *   - Registration is mocked via Phoenix join("ok", { agent_id }).
 *   - The OpenCode `client` is a plain object with mock methods.
 *
 * Observable proxies:
 *   - `handleSessionCreated` ↔ `client.session.prompt` called with identity msg
 *   - `handleSessionCreated` NOT called ↔ `client.session.prompt` NOT called
 *   - `handleSessionDeleted` ↔ `mockChannel.leave` + `mockSocket.disconnect` called
 *   - Tool shape ↔ presence of viche_discover / viche_send / viche_reply keys
 */

import { mock, describe, it, expect, beforeEach } from "bun:test";

// ---------------------------------------------------------------------------
// Phoenix mock — must be registered BEFORE the dynamic import of index.js
// ---------------------------------------------------------------------------

const mockChannelLeave = mock(() => {});
const mockChannelOn = mock((_event: string, _cb: unknown) => {});
const mockSocketConnect = mock(() => {});
const mockSocketDisconnect = mock(() => {});

/** Configures join() to resolve with "ok" after a short tick. */
function makeJoinOk() {
  return () => {
    const cbs: Record<string, (...args: unknown[]) => void> = {};
    const push = {
      receive(event: string, cb: (...args: unknown[]) => void) {
        cbs[event] = cb;
        if (event === "ok") {
          setTimeout(
            () => cb({ agent_id: "deadbeef-0000-4000-a000-000000000000" }),
            5
          );
        }
        return push;
      },
    };
    return push;
  };
}

const mockChannelJoin = mock(makeJoinOk());

const mockChannel = {
  join: mockChannelJoin,
  on: mockChannelOn,
  leave: mockChannelLeave,
};

const mockSocketChannel = mock((_topic: string, _params: unknown) => mockChannel);

class MockSocket {
  connect = mockSocketConnect;
  disconnect = mockSocketDisconnect;
  channel = mockSocketChannel;
}

// Register the phoenix mock before importing index.js.
mock.module("phoenix", () => ({ Socket: MockSocket }));

// Dynamic import so the phoenix mock is active when service.ts is loaded.
const { default: vichePlugin } = await import("../index.js");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeClient() {
  return {
    session: {
      prompt: mock(() => Promise.resolve(undefined)),
      promptAsync: mock(() => Promise.resolve(undefined)),
    },
  };
}

/** Build a plugin hooks object and the client it was created with. */
async function buildHooks() {
  const client = makeClient();
  const hooks = await vichePlugin({ client, directory: "/test/project" });
  return { hooks, client };
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe("vichePlugin", () => {
  beforeEach(() => {
    // Reset Phoenix mock call counts.
    mockChannelJoin.mockReset();
    mockChannelJoin.mockImplementation(makeJoinOk());
    mockChannelOn.mockReset();
    mockChannelLeave.mockReset();
    mockSocketConnect.mockReset();
    mockSocketDisconnect.mockReset();
    mockSocketChannel.mockReset();
    mockSocketChannel.mockImplementation((_topic: string, _params: unknown) => mockChannel);
  });

  // ── 1. Plugin returns correct hooks shape ──────────────────────────────────

  it("returns hooks object with event and tool keys", async () => {
    const { hooks } = await buildHooks();

    expect(hooks).toHaveProperty("event");
    expect(hooks).toHaveProperty("tool");
    expect(typeof hooks.event).toBe("function");
    expect(typeof hooks.tool).toBe("object");
  });

  // ── 2. session.created for root session calls handleSessionCreated ─────────
  // Observable proxy: client.session.prompt is called with the identity message.

  it("session.created for root session triggers agent registration and identity prompt", async () => {
    const { hooks, client } = await buildHooks();

    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "sess-root-001" } },
      },
    });

    expect(client.session.prompt).toHaveBeenCalledTimes(1);
    const [call] = (client.session.prompt as ReturnType<typeof mock>).mock.calls;
    const body = (call as [{ body: { parts: Array<{ text: string }> } }])[0].body;
    expect(body.parts[0]?.text).toContain("Viche Network Connected");
  });

  // ── 3. session.created for subtask (has parentID) skips registration ───────
  // Observable proxy: client.session.prompt is NOT called.

  it("session.created for subtask session (has parentID) does not trigger agent registration", async () => {
    const { hooks, client } = await buildHooks();

    await hooks.event({
      event: {
        type: "session.created",
        properties: {
          info: { id: "sess-sub-001", parentID: "sess-parent-001" },
        },
      },
    });

    expect(client.session.prompt).not.toHaveBeenCalled();
  });

  // ── 4. session.deleted calls handleSessionDeleted ─────────────────────────
  // Observable proxy: channel.leave() and socket.disconnect() are called.

  it("session.deleted triggers channel leave and socket disconnect", async () => {
    const { hooks } = await buildHooks();

    // Create the session first.
    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "sess-del-001" } },
      },
    });

    // Reset call counts so we can track only the deletion side-effects.
    mockChannelLeave.mockClear();
    mockSocketDisconnect.mockClear();

    hooks.event({
      event: {
        type: "session.deleted",
        properties: { info: { id: "sess-del-001" } },
      },
    });

    expect(mockChannelLeave).toHaveBeenCalledTimes(1);
    expect(mockSocketDisconnect).toHaveBeenCalledTimes(1);
  });

  // ── 5. Returned tool object has the three Viche tools ─────────────────────

  it("tool record contains viche_discover, viche_send, and viche_reply", async () => {
    const { hooks } = await buildHooks();

    expect(hooks.tool).toHaveProperty("viche_discover");
    expect(hooks.tool).toHaveProperty("viche_send");
    expect(hooks.tool).toHaveProperty("viche_reply");
  });

  // ── 6. Unknown event types are ignored ────────────────────────────────────

  it("ignores unknown event types without throwing", async () => {
    const { hooks, client } = await buildHooks();

    await expect(
      hooks.event({ event: { type: "unknown.event", properties: {} } })
    ).resolves.toBeUndefined();

    expect(client.session.prompt).not.toHaveBeenCalled();
  });

  // ── 7. session.created with missing session ID is ignored ─────────────────

  it("ignores session.created when properties.info.id is absent", async () => {
    const { hooks, client } = await buildHooks();

    await hooks.event({
      event: { type: "session.created", properties: {} },
    });

    expect(client.session.prompt).not.toHaveBeenCalled();
  });

  // ── 8. session.deleted for unknown session ID does not throw ───────────────

  it("session.deleted for an unknown session ID does not throw", async () => {
    const { hooks } = await buildHooks();

    await expect(
      hooks.event({
        event: {
          type: "session.deleted",
          properties: { info: { id: "unknown-session" } },
        },
      })
    ).resolves.toBeUndefined();
  });

  // ── 9. Each plugin invocation creates its own isolated state ──────────────

  it("two plugin invocations have independent state", async () => {
    // Two separate plugin instances.
    const client1 = makeClient();
    const client2 = makeClient();

    const hooks1 = await vichePlugin({ client: client1, directory: "/proj1" });
    const hooks2 = await vichePlugin({ client: client2, directory: "/proj2" });

    // Create a session in instance 1.
    await hooks1.event({
      event: {
        type: "session.created",
        properties: { info: { id: "sess-a" } },
      },
    });

    // Session deletion in instance 2 for the same ID should be a no-op
    // (state is not shared), so no throw.
    await expect(
      hooks2.event({
        event: {
          type: "session.deleted",
          properties: { info: { id: "sess-a" } },
        },
      })
    ).resolves.toBeUndefined();

    // client2.session.prompt should not have been called.
    expect(client2.session.prompt).not.toHaveBeenCalled();
  });
});
