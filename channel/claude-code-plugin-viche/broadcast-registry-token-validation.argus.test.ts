// Argus finding: type invariant violation in channel/claude-code-plugin-viche/tools.ts:viche_broadcast
// Scores: encapsulation=3, expression=2, usefulness=7, enforcement=3

import { describe, expect, it, mock } from "bun:test";
import { type RequestHandlerExtra } from "@modelcontextprotocol/sdk/shared/protocol.js";
import { CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { registerToolHandlers } from "./tools.js";

type CallToolHandler = (
  request: {
    method: "tools/call";
    params: { name: string; arguments?: Record<string, unknown> };
  },
  extra: RequestHandlerExtra,
) => Promise<{ content: Array<{ type: string; text: string }> }>;

describe("Argus: viche_broadcast should reject invalid registry token", () => {
  it("rejects malformed registry tokens before channel push", async () => {
    let callHandler: CallToolHandler | null = null;

    const channel = {
      push: mock((_event: string, _body: unknown) => ({
        receive(kind: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
          if (kind === "ok") cb({ recipients: 1 });
          return this;
        },
      })),
    };

    const server = {
      setRequestHandler: mock((schema: unknown, handler: unknown) => {
        if (schema === CallToolRequestSchema) {
          callHandler = handler as CallToolHandler;
        }
      }),
    };

    registerToolHandlers(
      server as never,
      () => channel as never,
      () => "agent-self",
      () => new Map(),
    );

    if (!callHandler) throw new Error("Expected call handler");

    const response = await callHandler(
      {
        method: "tools/call",
        params: {
          name: "viche_broadcast",
          arguments: { registry: "bad token!", body: "hello", type: "task" },
        },
      },
      {
        signal: undefined,
        sendNotification: async () => undefined,
        sendRequest: async () => ({}) as never,
      },
    );

    expect(channel.push).not.toHaveBeenCalled();
    expect(response.content[0]?.text).toContain("invalid");
  });
});
