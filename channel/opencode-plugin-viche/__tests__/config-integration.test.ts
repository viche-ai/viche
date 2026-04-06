/**
 * Integration test: proves that `registryUrl` from `.opencode/viche.json` is
 * picked up when the plugin initialises, with `VICHE_REGISTRY_URL` env var
 * taking highest priority.
 *
 * Mock strategy (mirrors index.test.ts):
 *   - `phoenix` is mocked via mock.module before the dynamic import.
 *   - Socket constructor args are captured to verify ws URL resolution.
 *   - The OpenCode `client` is a plain object with mock methods.
 *   - A real temp directory is used so `.opencode/viche.json` is read from disk.
 */

import { mock, describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ---------------------------------------------------------------------------
// Phoenix mock — must be registered BEFORE the dynamic import of index.js
// (same pattern as index.test.ts)
// ---------------------------------------------------------------------------

const mockChannelLeave = mock(() => {});
const mockChannelOn = mock((_event: string, _cb: unknown) => {});
const mockSocketConnect = mock(() => {});
const mockSocketDisconnect = mock(() => {});
const socketConstructorArgs: Array<[string, unknown?]> = [];

/** Configures join() to resolve with "ok" after a short tick. */
function makeJoinOk() {
  return () => {
    const cbs: Record<string, (...args: unknown[]) => void> = {};
    const push = {
      receive(event: string, cb: (...args: unknown[]) => void) {
        cbs[event] = cb;
        if (event === "ok") {
          setTimeout(
            () => cb({ agent_id: "aaaabbbb-0000-4000-a000-000000000001" }),
            5
          );
        }
        return push;
      },
    };
    return push;
  };
}

const mockChannelJoin = mock(makeJoinOk());

const mockChannel = {
  join: mockChannelJoin,
  on: mockChannelOn,
  leave: mockChannelLeave,
};

const mockSocketChannel = mock((_topic: string, _params: unknown) => mockChannel);

class MockSocket {
  connect = mockSocketConnect;
  disconnect = mockSocketDisconnect;
  channel = mockSocketChannel;

  constructor(url: string, opts?: unknown) {
    socketConstructorArgs.push([url, opts]);
  }
}

// Register phoenix mock before the dynamic import so service.ts picks it up.
mock.module("phoenix", () => ({ Socket: MockSocket }));

// Dynamic import so the phoenix mock is active when service.ts is loaded.
const { default: vichePlugin } = await import("../index.js");

// ---------------------------------------------------------------------------
// Env var keys that could affect config loading — saved and restored per test.
// ---------------------------------------------------------------------------

const ENV_KEYS = [
  "VICHE_REGISTRY_URL",
  "VICHE_AGENT_NAME",
  "VICHE_CAPABILITIES",
  "VICHE_DESCRIPTION",
  "VICHE_REGISTRY_TOKEN",
] as const;

type SavedEnv = Record<(typeof ENV_KEYS)[number], string | undefined>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Create a temp project directory and write `.opencode/viche.json`. */
function makeTempProjectDir(fileConfig: Record<string, unknown>): string {
  const dir = join(
    tmpdir(),
    `opencode-plugin-viche-config-integration-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  mkdirSync(join(dir, ".opencode"), { recursive: true });
  writeFileSync(
    join(dir, ".opencode", "viche.json"),
    JSON.stringify(fileConfig, null, 2) + "\n",
    "utf-8"
  );
  return dir;
}

function makeClient() {
  return {
    session: {
      prompt: mock(() => Promise.resolve(undefined)),
      promptAsync: mock(() => Promise.resolve(undefined)),
    },
  };
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe("vichePlugin — registryUrl config file integration", () => {
  let savedEnv: SavedEnv;
  let tempDir: string | undefined;

  beforeEach(() => {
    // Save and clear all Viche-related env vars so tests start from a clean slate.
    savedEnv = {} as SavedEnv;
    for (const key of ENV_KEYS) {
      savedEnv[key] = process.env[key];
      delete process.env[key];
    }

    tempDir = undefined;
    socketConstructorArgs.length = 0;

    // Reset Phoenix mock call counts.
    mockChannelJoin.mockReset();
    mockChannelJoin.mockImplementation(makeJoinOk());
    mockChannelOn.mockReset();
    mockChannelLeave.mockReset();
    mockSocketConnect.mockReset();
    mockSocketDisconnect.mockReset();
    mockSocketChannel.mockReset();
    mockSocketChannel.mockImplementation(
      (_topic: string, _params: unknown) => mockChannel
    );
  });

  afterEach(() => {
    // Restore env vars.
    for (const key of ENV_KEYS) {
      if (savedEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = savedEnv[key];
      }
    }

    // Clean up temp directory.
    if (tempDir !== undefined) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  it("uses registryUrl from .opencode/viche.json when VICHE_REGISTRY_URL env var is absent", async () => {
    const CUSTOM_URL = "http://custom-viche:9999";

    // Write a project config with a custom registryUrl.
    // Also provide `registries` to prevent loadConfig from auto-generating a
    // token and rewriting the file (which could obscure the URL bug).
    tempDir = makeTempProjectDir({
      registryUrl: CUSTOM_URL,
      registries: ["test-integration-token"],
    });

    // Ensure VICHE_REGISTRY_URL is NOT set (cleared in beforeEach, but be explicit).
    delete process.env.VICHE_REGISTRY_URL;

    const client = makeClient();

    // Initialise the plugin pointing at the temp project directory.
    const hooks = await vichePlugin({ client, directory: tempDir });

    // Trigger a root session creation, which causes agent registration.
    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "sess-config-integration-001" } },
      },
    });

    expect(socketConstructorArgs).toHaveLength(1);
    expect(socketConstructorArgs[0]?.[0]).toBe("ws://custom-viche:9999/agent/websocket");
  });

  // ── Sanity: VICHE_REGISTRY_URL env var still takes effect ─────────────────

  it("uses VICHE_REGISTRY_URL env var when set (env var overrides file)", async () => {
    const ENV_URL = "http://env-override-viche:8888";

    // Write a config file with a DIFFERENT URL to confirm env var wins.
    tempDir = makeTempProjectDir({
      registryUrl: "http://from-file-should-be-overridden:5555",
      registries: ["test-integration-token"],
    });

    process.env.VICHE_REGISTRY_URL = ENV_URL;

    const client = makeClient();
    const hooks = await vichePlugin({ client, directory: tempDir });

    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "sess-config-integration-002" } },
      },
    });

    expect(socketConstructorArgs).toHaveLength(1);
    expect(socketConstructorArgs[0]?.[0]).toBe("ws://env-override-viche:8888/agent/websocket");
  });
});
