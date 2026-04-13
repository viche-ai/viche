// Argus finding: type invariant violation in channel/openclaw-plugin-viche/tools.ts:viche_broadcast
// Scores: encapsulation=3, expression=2, usefulness=8, enforcement=3

import { describe, expect, it } from "bun:test";
import { registerVicheTools } from "./tools.ts";

type ToolFactory = (ctx: { sessionKey?: string }) => {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
  ) => Promise<{ content: Array<{ type: string; text: string }> }>;
};

function createApi() {
  const factories: ToolFactory[] = [];
  return {
    factories,
    registerTool(factory: ToolFactory) {
      factories.push(factory);
    },
  };
}

describe("Argus: viche_broadcast should reject invalid message type", () => {
  it("rejects non-protocol message types before sending", async () => {
    const pushes: Array<{ event: string; payload: Record<string, unknown> }> = [];

    const channel = {
      push(event: string, payload: Record<string, unknown>) {
        pushes.push({ event, payload });
        return {
          receive(kind: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
            if (kind === "ok") cb({ recipients: 1 });
            return this;
          },
        };
      },
    };

    const state = {
      agentId: "self-agent",
      channel,
      correlations: new Map<string, { sessionKey: string; timestamp: number }>(),
      mostRecentSessionKey: null as string | null,
    };

    const api = createApi();
    registerVicheTools(
      api as never,
      { registryUrl: "http://unused", capabilities: ["coding"] } as never,
      state as never,
    );

    const toolFactory = api.factories.find((f) => f({ sessionKey: "s1" }).name === "viche_broadcast");
    if (!toolFactory) throw new Error("Missing viche_broadcast tool");

    const tool = toolFactory({ sessionKey: "s1" });
    const result = await tool.execute("call-1", {
      registry: "team-alpha",
      body: "hello",
      type: "system-admin",
    });

    expect(pushes.length).toBe(0);
    expect(result.content[0]?.text).toContain("invalid");
  });
});
