import { describe, expect, it, mock } from "bun:test";
import { type RequestHandlerExtra } from "@modelcontextprotocol/sdk/shared/protocol.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { registerToolHandlers } from "./tools.js";

type CallToolHandler = (
  request: {
    method: "tools/call";
    params: { name: string; arguments?: Record<string, unknown> };
  },
  extra: RequestHandlerExtra
) => Promise<{ content: Array<{ type: string; text: string }> }>;

type ListToolsHandler = (
  request: { method: "tools/list"; params?: Record<string, unknown> },
  extra: RequestHandlerExtra
) => Promise<{ tools: unknown[] }>;

function makeChannelOk(payload: unknown) {
  return {
    push: mock((_event: string, _body: unknown) => ({
      receive(kind: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
        if (kind === "ok") cb(payload);
        return this;
      },
    })),
  };
}

function setupHandlers(channelPayload: unknown) {
  let callHandler: CallToolHandler | null = null;
  let listHandler: ListToolsHandler | null = null;

  const server = {
    setRequestHandler: mock((schema: unknown, handler: unknown) => {
      if (schema === CallToolRequestSchema) {
        callHandler = handler as CallToolHandler;
      }
      if (schema === ListToolsRequestSchema) {
        listHandler = handler as ListToolsHandler;
      }
    }),
  };

  registerToolHandlers(
    server as never,
    () => makeChannelOk(channelPayload) as never,
    () => "agent-self",
    () => new Map(),
  );

  if (!callHandler || !listHandler) {
    throw new Error("Expected tool handlers to be registered");
  }

  return { callHandler, listHandler };
}

function setupHandlersWithChannel(getChannel: () => unknown) {
  let callHandler: CallToolHandler | null = null;

  const server = {
    setRequestHandler: mock((schema: unknown, handler: unknown) => {
      if (schema === CallToolRequestSchema) {
        callHandler = handler as CallToolHandler;
      }
    }),
  };

  registerToolHandlers(
    server as never,
    getChannel as never,
    () => "agent-self",
    () => new Map(),
  );

  if (!callHandler) {
    throw new Error("Expected call tool handler to be registered");
  }

  return { callHandler };
}

describe("registerToolHandlers", () => {
  it("viche_join_registry rejects malformed ack payload", async () => {
    const { callHandler } = setupHandlers({});

    const response = await callHandler(
      {
        method: "tools/call",
        params: {
          name: "viche_join_registry",
          arguments: { token: "team-a" },
        },
      },
      {
        signal: undefined,
        sendNotification: async () => undefined,
        sendRequest: async () => ({}) as never,
      },
    );

    expect(response.content[0]?.text).toBe(
      "Failed to join registry: invalid registries response",
    );
  });

  it("viche_broadcast pushes broadcast_message and formats success", async () => {
    const channel = makeChannelOk({ recipients: 3 });
    const { callHandler } = setupHandlersWithChannel(() => channel as never);

    const response = await callHandler(
      {
        method: "tools/call",
        params: {
          name: "viche_broadcast",
          arguments: { registry: "team-alpha", body: "Deploy now", type: "task" },
        },
      },
      {
        signal: undefined,
        sendNotification: async () => undefined,
        sendRequest: async () => ({}) as never,
      },
    );

    expect(channel.push).toHaveBeenCalledWith("broadcast_message", {
      registry: "team-alpha",
      body: "Deploy now",
      type: "task",
    });
    expect(response.content[0]?.text).toBe(
      "Broadcast sent to 3 agent(s) in registry 'team-alpha'.",
    );
  });

  it("viche_broadcast returns not-connected message when channel is unavailable", async () => {
    const { callHandler } = setupHandlersWithChannel(() => null);

    const response = await callHandler(
      {
        method: "tools/call",
        params: {
          name: "viche_broadcast",
          arguments: { registry: "team-alpha", body: "Deploy now" },
        },
      },
      {
        signal: undefined,
        sendNotification: async () => undefined,
        sendRequest: async () => ({}) as never,
      },
    );

    expect(response.content[0]?.text).toContain("Not connected to Viche registry yet");
  });

  it("viche_broadcast formats channel errors", async () => {
    const channel = {
      push: mock((_event: string, _body: unknown) => ({
        receive(kind: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
          if (kind === "error") cb({ message: "not_in_registry" });
          return this;
        },
      })),
    };
    const { callHandler } = setupHandlersWithChannel(() => channel as never);

    const response = await callHandler(
      {
        method: "tools/call",
        params: {
          name: "viche_broadcast",
          arguments: { registry: "team-alpha", body: "Deploy now" },
        },
      },
      {
        signal: undefined,
        sendNotification: async () => undefined,
        sendRequest: async () => ({}) as never,
      },
    );

    expect(response.content[0]?.text).toBe("Failed to broadcast: not_in_registry");
  });
});
