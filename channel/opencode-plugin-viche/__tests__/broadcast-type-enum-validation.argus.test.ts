// Argus finding: type invariant violation in channel/opencode-plugin-viche/tools.ts:viche_broadcast
// Scores: encapsulation=4, expression=3, usefulness=8, enforcement=4

import { describe, expect, it, mock } from "bun:test";
import { createVicheTools } from "../tools.js";
import type { SessionState, VicheConfig, VicheState } from "../types.js";

function makeConfig(): VicheConfig {
  return {
    registryUrl: "http://localhost:4000",
    capabilities: ["coding"],
  };
}

function makeState(): VicheState {
  return {
    sessions: new Map(),
    initializing: new Map(),
  };
}

describe("Argus: opencode viche_broadcast should restrict message type", () => {
  it("rejects non-protocol type values before channel push", async () => {
    const push = mock((_event: string, _payload: Record<string, unknown>) => ({
      receive(status: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
        if (status === "ok") cb({ recipients: 1 });
        return this;
      },
    }));

    const sessionState: SessionState = {
      agentId: "abc123de-0000-4000-a000-000000000000",
      socket: {},
      channel: { push },
    };

    const ensureSessionReady = mock((_sessionID: string) => Promise.resolve(sessionState));

    const tools = createVicheTools(makeConfig(), makeState(), ensureSessionReady);
    const result = await tools.viche_broadcast.execute(
      {
        registry: "team-alpha",
        body: "hello",
        type: "system-admin",
      },
      { sessionID: "s1" },
    );

    expect(push).not.toHaveBeenCalled();
    expect(result).toContain("invalid");
  });
});
