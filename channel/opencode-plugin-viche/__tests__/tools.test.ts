import { describe, it, expect, mock } from "bun:test";
import { createVicheTools } from "../tools.js";
import type { SessionState, VicheConfig, VicheState } from "../types.js";

type PushStatus = "ok" | "error" | "timeout";

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

function makeChannelPush(responseStatus: PushStatus, responsePayload?: unknown) {
  return mock((event: string, payload: Record<string, unknown>) => {
    const chain = {
      receive(status: PushStatus, cb: (resp?: unknown) => void) {
        if (status === responseStatus) cb(responsePayload);
        return chain;
      },
    };

    // Preserve call args for assertions via Bun mock calls.
    void event;
    void payload;
    return chain;
  });
}

function makeSessionState(pushImpl: ReturnType<typeof makeChannelPush>): SessionState {
  return {
    agentId: "abc123de-0000-4000-a000-000000000000",
    socket: {},
    channel: {
      push: pushImpl,
    },
  };
}

const TEST_CONTEXT = { sessionID: "test-session" };

describe("createVicheTools (WebSocket transport)", () => {
  it("viche_discover uses channel.push('discover') and formats agents", async () => {
    const push = makeChannelPush("ok", {
      agents: [{ id: "a1", name: "Coder", capabilities: ["coding"], description: "agent" }],
    });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_discover.execute({ capability: "coding" }, TEST_CONTEXT);

    expect(ensureSessionReady).toHaveBeenCalledWith("test-session");
    expect(push).toHaveBeenCalledTimes(1);
    const [event, payload] = push.mock.calls[0] as [string, Record<string, unknown>];
    expect(event).toBe("discover");
    expect(payload).toEqual({ capability: "coding", registry: "global" });
    expect(result).toContain("Found 1 agent(s)");
    expect(result).toContain("Coder");
  });

  it("viche_send uses send_message channel event without from", async () => {
    const push = makeChannelPush("ok", { message_id: "msg-1" });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_send.execute(
      {
        to: "deadbeef-0000-4000-a000-000000000000",
        body: "Please review this code",
        type: "task",
      },
      TEST_CONTEXT
    );

    expect(push).toHaveBeenCalledTimes(1);
    const [event, payload] = push.mock.calls[0] as [string, Record<string, unknown>];
    expect(event).toBe("send_message");
    expect(payload).toEqual({
      to: "deadbeef-0000-4000-a000-000000000000",
      body: "Please review this code",
      type: "task",
    });
    expect(payload.from).toBeUndefined();
    expect(result).toContain("Message sent to deadbeef-0000-4000-a000-000000000000");
  });

  it("viche_reply uses send_message with type result and no from", async () => {
    const push = makeChannelPush("ok", { message_id: "msg-2" });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_reply.execute(
      { to: "cafebabe-0000-4000-a000-000000000000", body: "Done" },
      TEST_CONTEXT
    );

    expect(push).toHaveBeenCalledTimes(1);
    const [event, payload] = push.mock.calls[0] as [string, Record<string, unknown>];
    expect(event).toBe("send_message");
    expect(payload).toEqual({
      to: "cafebabe-0000-4000-a000-000000000000",
      body: "Done",
      type: "result",
    });
    expect(payload.from).toBeUndefined();
    expect(result).toContain("Reply sent to cafebabe-0000-4000-a000-000000000000");
  });

  it("returns channel timeout as a friendly error", async () => {
    const push = makeChannelPush("timeout");
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );
    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);

    const result = await tools.viche_send.execute(
      { to: "deadbeef-0000-4000-a000-000000000000", body: "Hello" },
      TEST_CONTEXT
    );

    expect(result).toContain("Failed to send message");
    expect(result).toContain("timeout");
  });

  it("returns parse error when discovery payload shape is invalid", async () => {
    const push = makeChannelPush("ok", {
      agents: { not: "an array" },
    });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );
    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);

    const result = await tools.viche_discover.execute({ capability: "coding" }, TEST_CONTEXT);
    expect(result).toBe("Failed to parse discovery response from Viche.");
  });

  it("viche_join_registry pushes join_registry and formats success", async () => {
    const push = makeChannelPush("ok", {
      registries: ["global", "new-team"],
    });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_join_registry.execute(
      { token: "new-team" },
      TEST_CONTEXT
    );

    expect(push).toHaveBeenCalledWith("join_registry", { token: "new-team" });
    expect(result).toBe("Joined registry 'new-team'. Current registries: global, new-team");
  });

  it("viche_join_registry formats channel error", async () => {
    const push = makeChannelPush("error", { error: "already_in_registry" });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_join_registry.execute(
      { token: "global" },
      TEST_CONTEXT
    );

    expect(result).toBe("Failed to join registry: already_in_registry");
  });

  it("viche_list_my_registries pushes list_registries and formats success", async () => {
    const push = makeChannelPush("ok", {
      registries: ["global", "team-a"],
    });
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_list_my_registries.execute({}, TEST_CONTEXT);

    expect(push).toHaveBeenCalledWith("list_registries", {});
    expect(result).toBe("Your registries: global, team-a");
  });

  it("viche_list_my_registries formats channel error", async () => {
    const push = makeChannelPush("timeout");
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_list_my_registries.execute({}, TEST_CONTEXT);

    expect(result).toContain("Failed to list registries: Channel timeout during list_registries");
  });

  it("viche_whoami returns the session agent ID", async () => {
    const push = makeChannelPush("ok");
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_whoami.execute({}, TEST_CONTEXT);

    expect(result).toBe("Your agent ID: abc123de-0000-4000-a000-000000000000");
  });

  it("viche_whoami returns error when session fails to initialise", async () => {
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.reject(new Error("registration failed"))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_whoami.execute({}, TEST_CONTEXT);

    expect(result).toBe("Failed to initialise session: registration failed");
  });

  it("viche_leave_registry rejects malformed ack payload", async () => {
    const push = makeChannelPush("ok", {});
    const ensureSessionReady = mock((_sessionID: string) =>
      Promise.resolve(makeSessionState(push))
    );

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_leave_registry.execute(
      { registry: "team-a" },
      TEST_CONTEXT
    );

    expect(result).toBe("Failed to leave registry: invalid registries response");
  });
});
