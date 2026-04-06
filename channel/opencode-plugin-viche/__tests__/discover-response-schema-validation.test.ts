// Argus finding: missing schema validation for discovery response allows malformed agent payloads
// Scores: encapsulation=3, expression=2, usefulness=7, enforcement=2

import { describe, it, expect, mock, afterEach } from "bun:test";
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
  channel: {},
};

describe("Argus: discovery response invariant enforcement", () => {
  afterEach(() => {
    (global as unknown as Record<string, unknown>)["fetch"] = undefined;
  });

  it("should reject malformed agent capabilities from discovery response, but currently crashes", async () => {
    const config = makeConfig();
    const state = makeState();
    const ensureSessionReady = mock((_sessionID: string) => Promise.resolve(fakeSessionState));
    const tools = createVicheTools(config, state, ensureSessionReady);

    // Invalid domain state entering from API boundary: capabilities must be string[]
    // but response contains a number.
    global.fetch = mock(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        statusText: "OK",
        json: () => Promise.resolve({ agents: [{ id: "bad-agent", capabilities: 42 }] }),
      } as Response)
    );

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
