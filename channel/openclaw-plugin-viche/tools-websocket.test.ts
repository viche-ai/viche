import { beforeEach, describe, expect, it, mock } from "bun:test";

import { registerVicheTools } from "./tools.ts";

type ToolFactory = (ctx: { sessionKey?: string }) => {
  name: string;
  execute: (toolCallId: string, params: Record<string, unknown>) => Promise<{ content: Array<{ type: string; text: string }> }>;
};

type PushStatus = "ok" | "error" | "timeout";

function createChannel(status: PushStatus, payload: unknown) {
  return {
    push: mock((_event: string, _body: unknown) => ({
      receive(kind: PushStatus, cb: (resp?: unknown) => void) {
        if (kind === status) cb(payload);
        return this;
      },
    })),
  };
}

function createApi() {
  const factories: ToolFactory[] = [];
  return {
    factories,
    registerTool(factory: ToolFactory) {
      factories.push(factory);
    },
  };
}

function getTool(api: ReturnType<typeof createApi>, name: string, sessionKey = "agent:tenant-a:session-1") {
  const factory = api.factories.find((f) => f({ sessionKey }).name === name);
  if (!factory) throw new Error(`Missing tool ${name}`);
  return factory({ sessionKey });
}

describe("registerVicheTools over channel pushes", () => {
  beforeEach(() => {
    globalThis.fetch = mock(async () => {
      throw new Error("tools should not use fetch");
    }) as unknown as typeof fetch;
  });

  it("uses discover channel event for viche_discover", async () => {
    const api = createApi();
    const channel = createChannel("ok", {
      agents: [{ id: "agent-1", name: "agent-one", capabilities: ["coding"] }],
    });
    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_discover");
    const result = await tool.execute("call-1", { capability: "coding" });

    expect(channel.push).toHaveBeenCalledWith("discover", { capability: "coding" });
    expect(result.content[0]?.text).toContain("Found 1 agent");
    expect((globalThis.fetch as unknown as { mock: { calls: unknown[] } }).mock.calls.length).toBe(0);
  });

  it("uses send_message channel event without from in viche_send and viche_reply", async () => {
    const api = createApi();
    const messageId = "msg-550e8400-e29b-41d4-a716-446655440000";
    const channel = createChannel("ok", { message_id: messageId });
    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const send = getTool(api, "viche_send", "agent:tenant-a:session-1");
    await send.execute("call-2", { to: "target-agent", body: "hello", type: "ping" });

    expect(channel.push).toHaveBeenCalledWith("send_message", {
      to: "target-agent",
      body: "hello",
      type: "ping",
    });
    expect(state.correlations.has(messageId)).toBeTrue();

    const reply = getTool(api, "viche_reply", "agent:tenant-b:session-2");
    await reply.execute("call-3", { to: "sender-agent", body: "done" });

    expect(channel.push).toHaveBeenCalledWith("send_message", {
      to: "sender-agent",
      body: "done",
      type: "result",
    });
    expect((globalThis.fetch as unknown as { mock: { calls: unknown[] } }).mock.calls.length).toBe(0);
  });

  it("viche_join_registry uses join_registry event and formats success", async () => {
    const api = createApi();
    const channel = createChannel("ok", { registries: ["global", "new-team"] });
    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_join_registry", "agent:tenant-a:session-1");
    const result = await tool.execute("call-join", { token: "new-team" });

    expect(channel.push).toHaveBeenCalledWith("join_registry", { token: "new-team" });
    expect(result.content[0]?.text).toBe("Joined registry 'new-team'. Current registries: global, new-team");
  });

  it("viche_list_my_registries uses list_registries event and formats success", async () => {
    const api = createApi();
    const channel = createChannel("ok", { registries: ["global", "team-a"] });
    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_list_my_registries", "agent:tenant-a:session-1");
    const result = await tool.execute("call-list", {});

    expect(channel.push).toHaveBeenCalledWith("list_registries", {});
    expect(result.content[0]?.text).toBe("Your registries: global, team-a");
  });

  it("viche_list_my_registries rejects malformed ack payload", async () => {
    const api = createApi();
    const channel = createChannel("ok", {});
    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_list_my_registries", "agent:tenant-a:session-1");
    const result = await tool.execute("call-list", {});

    expect(channel.push).toHaveBeenCalledWith("list_registries", {});
    expect(result.content[0]?.text).toBe(
      "Failed to list registries: invalid registries response",
    );
  });

  it("viche_whoami returns the agent's own ID without a channel push", async () => {
    const api = createApi();
    const channel = createChannel("ok", {});
    const state = {
      agentId: "my-agent-id-abc123",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_whoami");
    const result = await tool.execute("call-whoami", {});

    expect(channel.push).not.toHaveBeenCalled();
    expect(result.content[0]?.text).toBe("Your agent ID: my-agent-id-abc123");
  });

  it("viche_whoami returns not-connected message when agentId is null", async () => {
    const api = createApi();
    const channel = createChannel("ok", {});
    const state = {
      agentId: null as string | null,
      channel: null,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    registerVicheTools(api as any, { registryUrl: "http://unused", capabilities: ["coding"] } as any, state as any);

    const tool = getTool(api, "viche_whoami");
    const result = await tool.execute("call-whoami", {});

    expect(result.content[0]?.text).toContain("not yet connected");
  });
});
