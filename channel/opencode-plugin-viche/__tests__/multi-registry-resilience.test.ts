import { describe, expect, it, mock } from "bun:test";
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

const sessionState: SessionState = {
  agentId: "abc123de-0000-4000-a000-000000000000",
  socket: {},
  channel: {
    push: mock((_event: string, _payload: Record<string, unknown>) => ({
      receive(status: "ok" | "error" | "timeout", cb: (resp?: unknown) => void) {
        if (status === "error") cb({ message: "discovery failed" });
        return this;
      },
    })),
  },
};

function makeEnsureSessionReady() {
  return mock((_sessionID: string) => Promise.resolve(sessionState));
}

describe("Argus: discovery transport resilience", () => {
  it("returns a friendly error when channel discovery responds with error", async () => {
    const tools = createVicheTools(
      makeConfig({ registries: ["bad-registry", "good-registry"] }),
      makeState(),
      makeEnsureSessionReady()
    );

    const result = await tools.viche_discover.execute({ capability: "coding" }, { sessionID: "sess-1" });

    expect(result).toContain("Failed to discover agents");
    expect(result).toContain("discovery failed");
  });
});
