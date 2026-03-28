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
  AgentInfo,
  InboundMessagePayload,
  OpenClawPluginService,
  OpenClawPluginServiceContext,
  PluginLogger,
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
// Inbound message routing helpers
// ---------------------------------------------------------------------------

/** Hard-coded main session used as final fallback and for the explicit "main" policy. */
const MAIN_SESSION = "agent:main:main";

/** Correlation TTL: entries older than this are pruned on each inbound message. */
const CORRELATION_TTL_MS = 60 * 60 * 1_000; // 1 hour

/**
 * Resolve the target sessionKey for an inbound message.
 *
 * Routing priority:
 *   1. "result" messages with a `replyTo` field: look up the correlation map
 *      to find which session originally sent that message.
 *   2. "most-recent" policy (default when `defaultInboundSession` is unset or "most-recent"):
 *      use the last session that called viche_send or viche_reply (if any).
 *   3. Fall back to `agent:main:main` (explicit "main" config, or no active session yet).
 */
function resolveSessionKey(
  payload: InboundMessagePayload,
  config: VicheConfig,
  state: VicheState,
): string {
  // 1. Correlation-based routing for "result" replies.
  if (payload.type === "result" && payload.replyTo) {
    const entry = state.correlations.get(payload.replyTo);
    if (entry) {
      // Consume the correlation entry — one-time use.
      state.correlations.delete(payload.replyTo);
      return entry.sessionKey;
    }
  }

  // 2. "most-recent" policy (default): route to the last active session.
  // Only applies to "result" messages — unsolicited "task" messages must NOT be
  // routed to an arbitrary user's session to prevent cross-session injection.
  // Treat undefined (unset) the same as "most-recent" — only skip for explicit "main".
  if (
    payload.type === "result" &&
    config.defaultInboundSession !== "main" &&
    state.mostRecentSessionKey
  ) {
    return state.mostRecentSessionKey;
  }

  // 3. Fallback: main session (explicit "main" config, or no active session recorded yet).
  return MAIN_SESSION;
}

/**
 * Remove correlation entries older than CORRELATION_TTL_MS.
 * Called on each inbound message to keep the map bounded.
 */
function cleanupExpiredCorrelations(state: VicheState): void {
  const cutoff = Date.now() - CORRELATION_TTL_MS;
  for (const [id, entry] of state.correlations) {
    if (entry.timestamp < cutoff) {
      state.correlations.delete(id);
    }
  }
}

// ---------------------------------------------------------------------------
// Inbound message injection
// ---------------------------------------------------------------------------

async function handleInboundMessage(
  payload: InboundMessagePayload,
  runtime: PluginRuntime,
  config: VicheConfig,
  state: VicheState,
  logger: PluginLogger,
): Promise<void> {
  // Validate required fields before processing.
  // Throws for structurally invalid payloads so the caller can observe the failure.
  if (
    typeof payload.id !== "string" || payload.id === "" ||
    typeof payload.from !== "string" || payload.from === "" ||
    typeof payload.body !== "string"
  ) {
    throw new Error(
      `Viche: received inbound message with missing or invalid required fields: ${JSON.stringify(payload)}`,
    );
  }

  // Prune stale correlations on every inbound message (lazy cleanup).
  cleanupExpiredCorrelations(state);

  const label = payload.type === "result" ? "Result" : "Task";
  const message = `[Viche ${label} from ${payload.from}] ${payload.body}`;

  const sessionKey = resolveSessionKey(payload, config, state);

  try {
    const { runId } = await runtime.subagent.run({
      sessionKey,
      message,
      deliver: false,
      idempotencyKey: payload.id,
    });
    logger.info(
      `Viche: injected message ${payload.id} from ${payload.from} into session ${sessionKey} (runId: ${runId})`,
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

  /** True once stop() is called; prevents recovery from spawning new connections. */
  let stopped = false;
  /** True while a re-registration + reconnect is in progress; prevents retry storms. */
  let recovering = false;

  return {
    id: "viche-bridge",

    async start(ctx: OpenClawPluginServiceContext): Promise<void> {
      const logger = ctx.logger;
      stopped = false;
      recovering = false;

      // 1. Register with Viche (with retry)
      state.agentId = await registerWithRetry(config, logger);

      // Helper: create socket+channel and attempt a single join.
      // Returns the reason string on error, or null on timeout.
      const connectAndJoin = (agentId: string): Promise<void> => {
        const wsBase = config.registryUrl.replace(/^http/, "ws");
        socket = new Socket(`${wsBase}/agent/websocket`, {
          params: { agent_id: agentId },
          reconnectAfterMs: (tries: number) =>
            ([1000, 2000, 5000, 10000] as const)[tries - 1] ?? 10000,
        });

        socket.onClose(() => {
          logger.warn("Viche: WebSocket disconnected — will reconnect automatically");
        });

        socket.onOpen(() => {
          logger.info("Viche: WebSocket (re)connected");
        });

        socket.connect();

        channel = socket.channel(`agent:${agentId}`, {});

        // eslint-disable-next-line @typescript-eslint/no-unsafe-call
        channel.onClose?.(() => {
          logger.warn(`Viche: agent:${agentId} channel closed`);
        });

        // Fired when the channel rejoin is rejected by the server (e.g. agent_not_found
        // after the agent process was killed while the transport was disconnected).
        // We re-register to obtain a new agentId and reconnect on a fresh socket.
        // eslint-disable-next-line @typescript-eslint/no-unsafe-call
        channel.onError?.(async (reason: unknown) => {
          // Guard: ignore if stop() was called or recovery is already running.
          if (recovering || stopped) return;
          recovering = true;

          const reasonStr =
            typeof reason === "string" ? reason : JSON.stringify(reason);
          logger.warn(
            `Viche: channel error (${reasonStr}) — re-registering to recover`,
          );

          // Capture stale refs before nulling so stop() sees a clean state
          // even if it races with the async recovery below.
          const staleChannel = channel;
          const staleSocket = socket;
          channel = null;
          socket = null;

          // Stop Phoenix's internal rejoin-retry loop on the old channel.
          try {
            staleChannel?.leave();
          } catch {
            /* ignore */
          }

          // Drop the transport.
          try {
            staleSocket?.disconnect();
          } catch {
            /* ignore */
          }

          if (stopped) {
            recovering = false;
            return;
          }

          try {
            // Capture new ID before updating state so that a concurrent stop()
            // leaves state.agentId as null (set by stop()) rather than the new ID.
            const newAgentId = await registerWithRetry(config, logger);

            if (stopped) return;

            state.agentId = newAgentId;
            await connectAndJoin(state.agentId);
            logger.info(`Viche: recovered — re-registered as ${state.agentId}`);
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            logger.error(`Viche: channel recovery failed: ${msg}`);
          } finally {
            recovering = false;
          }
        });

        channel.on("new_message", async (payload: InboundMessagePayload) => {
          await handleInboundMessage(payload, runtime, config, state, logger);
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
                registryChannel
                  .join()
                  .receive("error", (resp: unknown) => {
                    logger.warn(
                      `Viche: registry channel join failed for ${token}: ${JSON.stringify(resp)}`
                    );
                  });
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

      // Signal recovery (if running) to abort before it spawns new connections.
      stopped = true;

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
