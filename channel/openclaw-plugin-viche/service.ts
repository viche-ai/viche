/**
 * Background service for openclaw-plugin-viche.
 *
 * Responsibilities:
 *   1. Register this OpenClaw instance with the Viche agent registry on startup
 *      (HTTP POST /registry/register, 3 attempts with 2 s backoff).
 *   2. Connect a Phoenix Channel WebSocket (`ws://.../agent/websocket`) and
 *      join `agent:{agentId}` to receive real-time messages.
 *   3. On `new_message` events, inject the message into the main agent session
 *      via `runtime.subagent.run()` so the user sees it with full context.
 *   4. On stop, leave the channel, disconnect the socket, and clear state.
 */

// @ts-ignore — phoenix ships CJS without ESM types; import works at runtime
import { Socket } from "phoenix";
import type {
  OpenClawPluginService,
  OpenClawPluginServiceContext,
  PluginLogger,
} from "openclaw/plugin-sdk/plugin-entry";
import type {
  AgentInfo,
  InboundMessagePayload,
  PluginRuntime,
  RegisterResponse,
  VicheConfig,
  VicheState,
} from "./types.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixSocket = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixChannel = any;

const MAX_ATTEMPTS = 3;
const BACKOFF_MS = 2_000;

// ---------------------------------------------------------------------------
// Registration helpers
// ---------------------------------------------------------------------------

async function registerOnce(config: VicheConfig): Promise<string> {
  const body: Record<string, unknown> = {
    capabilities: config.capabilities,
  };
  if (config.agentName) body.name = config.agentName;
  if (config.description) body.description = config.description;
  if (config.registries?.length) body.registries = config.registries;

  const resp = await fetch(`${config.registryUrl}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    throw new Error(`Registration failed: ${resp.status} ${resp.statusText}`);
  }

  const data = (await resp.json()) as RegisterResponse;
  if (!data.id || typeof data.id !== "string") {
    throw new Error(`Registration response missing agent id: ${JSON.stringify(data)}`);
  }
  return data.id;
}

async function registerWithRetry(
  config: VicheConfig,
  logger: PluginLogger,
): Promise<string> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      return await registerOnce(config);
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
      logger.error(
        `Viche: registration attempt ${attempt}/${MAX_ATTEMPTS} failed: ${lastError.message}`,
      );
      if (attempt < MAX_ATTEMPTS) {
        await sleep(BACKOFF_MS);
      }
    }
  }

  throw new Error(
    `Viche: registration failed after ${MAX_ATTEMPTS} attempts: ${lastError?.message ?? "unknown error"}`,
  );
}

// ---------------------------------------------------------------------------
// Inbound message injection into main session
// ---------------------------------------------------------------------------

async function handleInboundMessage(
  payload: InboundMessagePayload,
  runtime: PluginRuntime,
  logger: PluginLogger,
): Promise<void> {
  const label = payload.type === "result" ? "Result" : "Task";
  const message = `[Viche ${label} from ${payload.from}] ${payload.body}`;

  try {
    const { runId } = await runtime.subagent.run({
      sessionKey: "agent:main:main",
      message,
      deliver: false,
      idempotencyKey: payload.id,
    });
    logger.info(
      `Viche: injected message ${payload.id} from ${payload.from} into main session (runId: ${runId})`,
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.warn(`Viche: failed to inject message ${payload.id}: ${msg}`);
    // Do NOT rethrow — a transient failure must not crash the service.
  }
}

// ---------------------------------------------------------------------------
// Service factory
// ---------------------------------------------------------------------------

/**
 * Returns an OpenClawPluginService that manages the Viche WebSocket lifecycle.
 *
 * @param config        - Resolved plugin config (from types.VicheConfig).
 * @param state         - Shared mutable state object written by the service and
 *                        read by the tool handlers.
 * @param runtime       - OpenClaw PluginRuntime for spawning subagent sessions.
 * @param _openclawConfig - Full OpenClaw config (reserved for future use).
 */
export function createVicheService(
  config: VicheConfig,
  state: VicheState,
  runtime: PluginRuntime,
  _openclawConfig: unknown,
): OpenClawPluginService {
  let socket: PhoenixSocket | null = null;
  let channel: PhoenixChannel | null = null;

  return {
    id: "viche-bridge",

    async start(ctx: OpenClawPluginServiceContext): Promise<void> {
      const logger = ctx.logger;

      // 1. Register with Viche (with retry)
      state.agentId = await registerWithRetry(config, logger);

      // Helper: create socket+channel and attempt a single join.
      // Returns the reason string on error, or null on timeout.
      const connectAndJoin = (agentId: string): Promise<void> => {
        const wsBase = config.registryUrl.replace(/^http/, "ws");
        socket = new Socket(`${wsBase}/agent/websocket`, {
          params: { agent_id: agentId },
        });
        socket.connect();

        channel = socket.channel(`agent:${agentId}`, {});

        channel.on("new_message", (payload: InboundMessagePayload) => {
          void handleInboundMessage(payload, runtime, logger);
        });

        return new Promise<void>((resolve, reject) => {
          channel!
            .join()
            .receive("ok", () => {
              logger.info(
                `Viche: registered as ${agentId}, connected via WebSocket`,
              );

              for (const token of config.registries ?? []) {
                const registryChannel = socket!.channel(`registry:${token}`, {});
                registryChannel.join();
              }

              resolve();
            })
            .receive("error", (resp: unknown) => {
              reject(
                new Error(
                  `Viche: channel join failed: ${JSON.stringify(resp)}`,
                  { cause: resp },
                ),
              );
            })
            .receive("timeout", () => {
              reject(new Error("Viche: channel join timed out"));
            });
        });
      };

      // 2. Connect and join; on agent_not_found re-register once and retry.
      try {
        await connectAndJoin(state.agentId);
      } catch (err) {
        const cause = err instanceof Error ? (err.cause as Record<string, unknown> | undefined) : undefined;
        if (cause && cause.reason === "agent_not_found") {
          logger.warn("Viche: agent_not_found on channel join — re-registering");

          // Disconnect stale socket before creating a new one.
          try { socket?.disconnect(); } catch { /* ignore */ }
          socket = null;
          channel = null;

          state.agentId = await registerWithRetry(config, logger);
          await connectAndJoin(state.agentId);
        } else {
          throw err;
        }
      }
    },

    async stop(ctx: OpenClawPluginServiceContext): Promise<void> {
      const logger = ctx.logger;

      if (channel) {
        try {
          channel.leave();
        } catch {
          // Ignore errors during cleanup
        }
        channel = null;
      }

      if (socket) {
        try {
          socket.disconnect();
        } catch {
          // Ignore errors during cleanup
        }
        socket = null;
      }

      state.agentId = null;
      logger.info("Viche: disconnected and cleaned up");
    },
  };
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Re-export for use in tools.ts
export { type AgentInfo };
