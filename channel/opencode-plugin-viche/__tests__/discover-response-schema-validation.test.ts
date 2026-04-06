import { describe, it, expect, mock } from "bun:test";
import { createVicheTools } from "../tools.js";
import type { SessionState, VicheConfig, VicheState } from "../types.js";

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

const fakeSessionState: SessionState = {
  agentId: "abc123de-0000-4000-a000-000000000000",
  socket: {},
  channel: {
    push: mock((_event: string, _payload: Record<string, unknown>) => ({
      receive(status: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
        if (status === "ok") cb({ agents: [{ id: "bad-agent", capabilities: 42 }] });
        return this;
      },
    })),
  },
};

describe("Argus: discovery response invariant enforcement", () => {
  it("rejects malformed discovery payloads without throwing", async () => {
    const config = makeConfig();
    const state = makeState();
    const ensureSessionReady = mock((_sessionID: string) => Promise.resolve(fakeSessionState));
    const tools = createVicheTools(config, state, ensureSessionReady);

    let thrown: unknown;
    let result: string | undefined;

    try {
      result = await tools["viche_discover"]!.execute({ capability: "coding" }, { sessionID: "s-1" });
    } catch (err) {
      thrown = err;
    }

    // Expected behavior once fixed: malformed payload is handled gracefully (no throw)
    // and returns a parse/validation error message.
    expect(thrown).toBeUndefined();
    expect(result).toContain("Failed to parse discovery response from Viche.");
  });
});
