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
});
