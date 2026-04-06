import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
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
  channel: {},
};

function makeEnsureSessionReady() {
  return mock((_sessionID: string) => Promise.resolve(sessionState));
}

describe("Argus: multi-registry discovery resilience", () => {
  let originalFetch: typeof globalThis.fetch | undefined;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("continues discovery when one configured registry returns invalid JSON", async () => {
    const fetchMock = mock()
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        statusText: "OK",
        json: () => Promise.reject(new Error("invalid json")),
      } as Response)
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        statusText: "OK",
        json: () => Promise.resolve({ agents: [{ id: "good0001", capabilities: ["coding"] }] }),
      } as Response);

    globalThis.fetch = fetchMock;

    const tools = createVicheTools(
      makeConfig({ registries: ["bad-registry", "good-registry"] }),
      makeState(),
      makeEnsureSessionReady()
    );

    const result = await tools.viche_discover.execute({ capability: "coding" }, { sessionID: "sess-1" });

    expect(globalThis.fetch).toHaveBeenCalledTimes(2);
    expect(result).toContain("good0001");
    expect(result).not.toContain("invalid json");
  });
});
