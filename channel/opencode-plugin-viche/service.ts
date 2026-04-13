/**
 * Background service for opencode-plugin-viche.
 *
 * Responsibilities:
 *   1. Per-session agent lifecycle: connect WebSocket and register by joining
 *      the `agent:register` Phoenix Channel.
 *   2. Inject a [Viche Network Connected] identity message into each session
 *      on creation via `client.session.prompt`.
 *   3. Relay inbound `new_message` channel events into the session via
 *      `client.session.promptAsync`.
 *   4. Clean up channel + socket on session deletion or plugin shutdown.
 *
 * Design notes:
 *   - Each OpenCode session gets its own Viche agent registration and socket.
 *   - `ensureSessionReady` is idempotent: concurrent calls for the same
 *     session ID deduplicate through `state.initializing`.
 *   - Errors during registration propagate as thrown exceptions — we never
 *     call `process.exit()`.
 */

// @ts-ignore — phoenix ships CJS without ESM types; import works at runtime
import { Socket } from "phoenix";
import type {
  InboundMessagePayload,
  SessionState,
  VicheConfig,
  VicheState,
} from "./types.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixSocket = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixChannel = any;

const MAX_ATTEMPTS = 3;
const BACKOFF_MS = 2_000;

interface ConnectionLifecycleHandlers {
  onSocketClose?: () => void;
  onSocketOpen?: () => void;
  onChannelError?: (reason: unknown) => void;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

function registrationParams(config: VicheConfig): Record<string, unknown> {
  const params: Record<string, unknown> = {
    capabilities: config.capabilities,
  };
  if (config.agentName) params.name = config.agentName;
  if (config.description) params.description = config.description;
  if (config.registries?.length) params.registries = config.registries;
  return params;
}

async function registerAgent(
  config: VicheConfig,
  backoffMs: number,
  onMessage: (payload: InboundMessagePayload) => void,
  handlers: ConnectionLifecycleHandlers = {}
): Promise<{
  agentId: string;
  socket: PhoenixSocket;
  channel: PhoenixChannel;
  registryChannels: PhoenixChannel[];
}> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      return await connectWebSocket(config, onMessage, handlers);
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
      if (attempt < MAX_ATTEMPTS) {
        await sleep(backoffMs);
      }
    }
  }

  throw new Error(
    `Viche: registration failed after ${MAX_ATTEMPTS} attempts: ${lastError?.message ?? "unknown error"}`
  );
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

function connectWebSocket(
  config: VicheConfig,
  onMessage: (payload: InboundMessagePayload) => void,
  handlers: ConnectionLifecycleHandlers = {}
): Promise<{
  agentId: string;
  socket: PhoenixSocket;
  channel: PhoenixChannel;
  registryChannels: PhoenixChannel[];
}> {
  // Phoenix JS appends the transport suffix ("/websocket") to the endpoint.
  // The Viche socket is mounted at "/agent/websocket", so the full transport
  // URL becomes "/agent/websocket/websocket" — which is what the server expects.
  const wsBase = config.registryUrl.replace(/^http/, "ws");
  const socket: PhoenixSocket = new Socket(`${wsBase}/agent/websocket`, {
    reconnectAfterMs: (tries: number) =>
      ([1000, 2000, 5000, 10000] as const)[tries - 1] ?? 10000,
  });
  socket.onClose?.(() => {
    handlers.onSocketClose?.();
  });
  socket.onOpen?.(() => {
    handlers.onSocketOpen?.();
  });
  socket.connect();

  const channel: PhoenixChannel = socket.channel(
    "agent:register",
    registrationParams(config)
  );
  channel.on("new_message", (payload: InboundMessagePayload) =>
    onMessage(payload)
  );

  channel.onError?.((reason: unknown) => {
    handlers.onChannelError?.(reason);
  });

  // Socket cleanup is owned here: if join fails we disconnect before rejecting
  // so callers never hold a reference to a stale open socket.
  const cleanup = () => {
    try {
      socket.disconnect();
    } catch {
      /* ignore */
    }
  };

  return new Promise<{
    agentId: string;
    socket: PhoenixSocket;
    channel: PhoenixChannel;
    registryChannels: PhoenixChannel[];
  }>(
    (resolve, reject) => {
      const registryChannels: PhoenixChannel[] = [];
      channel
        .join()
        .receive("ok", (resp: unknown) => {
          const agentId =
            resp && typeof resp === "object"
              ? (resp as { agent_id?: unknown }).agent_id
              : undefined;

          if (typeof agentId !== "string" || agentId.length === 0) {
            cleanup();
            reject(
              new Error(
                `Viche: register join response missing agent_id: ${JSON.stringify(resp)}`
              )
            );
            return;
          }

          for (const token of config.registries ?? []) {
            const registryChannel = socket.channel(`registry:${token}`, {
              agent_id: agentId,
            });
            registryChannels.push(registryChannel);
            registryChannel
              .join()
              .receive("error", (resp: unknown) => {
                process.stderr.write(
                  `Viche: registry channel join failed for ${token}: ${JSON.stringify(resp)}\n`
                );
              });
          }
          resolve({ agentId, socket, channel, registryChannels });
        })
        .receive("error", (resp: unknown) => {
          cleanup();
          reject(
            new Error(`Viche: channel join failed: ${JSON.stringify(resp)}`, {
              cause: resp,
            })
          );
        })
        .receive("timeout", () => {
          cleanup();
          reject(new Error("Viche: channel join timed out"));
        });
    }
  );
}

function teardownSession(
  session: SessionState,
  options: { includeRegistryChannels?: boolean } = {}
): void {
  const includeRegistryChannels = options.includeRegistryChannels ?? true;

  try {
    (session.channel as PhoenixChannel).leave();
  } catch {
    /* ignore */
  }

  if (includeRegistryChannels) {
    for (const registryChannel of session.registryChannels ?? []) {
      try {
        (registryChannel as PhoenixChannel).leave();
      } catch {
        /* ignore */
      }
    }
  }

  try {
    (session.socket as PhoenixSocket).disconnect();
  } catch {
    /* ignore */
  }
}

// ---------------------------------------------------------------------------
// Service factory
// ---------------------------------------------------------------------------

/** Options accepted by {@link createVicheService}. All fields optional. */
export interface CreateVicheServiceOptions {
  /**
   * Milliseconds between registration retry attempts.
   * Defaults to 2000. Set to 0 in tests to avoid real delays.
   */
  backoffMs?: number;
}

/**
 * Creates the Viche service for an OpenCode plugin context.
 *
 * @param config    - Resolved plugin config.
 * @param state     - Shared mutable state (sessions + initializing maps).
 * @param client    - OpenCode SDK client (typed `any` to avoid runtime dep).
 * @param directory - Project directory passed through to prompt calls.
 * @param options   - Optional tuning: `backoffMs` (default 2000).
 */
export function createVicheService(
  config: VicheConfig,
  state: VicheState,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  client: any,
  directory: string,
  options: CreateVicheServiceOptions = {}
): {
  ensureSessionReady: (sessionID: string) => Promise<SessionState>;
  handleSessionCreated: (sessionID: string) => Promise<void>;
  handleSessionDeleted: (sessionID: string) => void;
  shutdown: () => void;
} {
  const effectiveBackoffMs = options.backoffMs ?? BACKOFF_MS;

  // Track sessions that were deleted while their initialization was in-flight.
  // Used by `ensureSessionReady` to reject the promise instead of returning a
  // session that was already cleaned up.
  const pendingDeletes = new Set<string>();

  // ---------------------------------------------------------------------------
  // Inbound message handler
  // ---------------------------------------------------------------------------

  async function handleInboundMessage(
    sessionID: string,
    payload: InboundMessagePayload
  ): Promise<void> {
    const label = payload.type === "result" ? "Result" : "Task";
    const threadParts: string[] = [];
    if (payload.in_reply_to) threadParts.push(`reply_to:${payload.in_reply_to}`);
    if (payload.conversation_id) threadParts.push(`thread:${payload.conversation_id}`);
    const threadContext = threadParts.length > 0 ? ` (${threadParts.join(" ")})` : "";
    // Sanitize body: replace newlines and carriage returns with a space to
    // prevent prompt-injection attacks that break out of the enclosing bracket.
    const sanitizedBody = payload.body.replace(/[\r\n]/g, " ");
    await client.session.promptAsync({
      path: { id: sessionID },
      body: {
        noReply: false,
        parts: [
          {
            type: "text",
            text: `[Viche ${label} from ${payload.from}${threadContext}] ${sanitizedBody}`,
          },
        ],
      },
      query: { directory },
    });
  }

  // ---------------------------------------------------------------------------
  // Session initialisation (single in-flight path)
  // ---------------------------------------------------------------------------

  async function initSession(sessionID: string): Promise<SessionState> {
    let recovering = false;

    const onMessage = (payload: InboundMessagePayload) => {
      // Reject messages whose ID does not conform to the AGENTS.md convention
      // ("msg-" prefix followed by UUID). This guards against malformed or
      // spoofed payloads reaching the LLM.
      if (typeof payload.id !== "string" || !payload.id.startsWith("msg-")) {
        return;
      }
      // Intentionally fire-and-forget; catch to prevent unhandled rejections.
      void handleInboundMessage(sessionID, payload).catch(() => {
        /* transient relay errors must not crash the message loop */
      });
    };

    const recoverSession = async (reason: unknown): Promise<void> => {
      if (recovering) return;
      const active = state.sessions.get(sessionID);
      if (active === undefined) return;

      recovering = true;

      const reasonString =
        typeof reason === "string" ? reason : JSON.stringify(reason);
      process.stderr.write(
        `Viche: channel error for session ${sessionID} (${reasonString}) — reconnecting and re-registering\n`
      );

      teardownSession(active, { includeRegistryChannels: false });

      if (!state.sessions.has(sessionID)) {
        recovering = false;
        return;
      }

      try {
        const recovered = await registerAgent(
          config,
          effectiveBackoffMs,
          onMessage,
          lifecycleHandlers
        );

        if (!state.sessions.has(sessionID)) {
          teardownSession(recovered);
          return;
        }

        active.agentId = recovered.agentId;
        active.channel = recovered.channel;
        active.socket = recovered.socket;
        active.registryChannels = recovered.registryChannels;
        state.sessions.set(sessionID, active);

      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        process.stderr.write(
          `Viche: session ${sessionID} recovery failed: ${message}\n`
        );
        state.sessions.delete(sessionID);
      } finally {
        recovering = false;
      }
    };

    const lifecycleHandlers: ConnectionLifecycleHandlers = {
      onChannelError: (reason: unknown) => {
        void recoverSession(reason);
      },
    };

    // connectWebSocket owns socket cleanup on join failure (disconnects before
    // rejecting) so we never hold a stale socket reference here.
    const { agentId, socket, channel, registryChannels } = await registerAgent(
      config,
      effectiveBackoffMs,
      onMessage,
      lifecycleHandlers
    );

    const sessionState: SessionState = { agentId, socket, channel, registryChannels };
    state.sessions.set(sessionID, sessionState);
    return sessionState;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  const service = {
    /**
     * Idempotent session initialisation.
     *
     * - Returns immediately if session is already initialised.
     * - Awaits the in-flight promise if initialisation is underway.
     * - Otherwise starts initialisation, memoising the promise to prevent
     *   duplicate registrations from concurrent callers.
     */
    async ensureSessionReady(sessionID: string): Promise<SessionState> {
      const existing = state.sessions.get(sessionID);
      if (existing !== undefined) return existing;

      const inflight = state.initializing.get(sessionID);
      if (inflight !== undefined) return inflight;

      const promise = initSession(sessionID)
        .then((session) => {
          // If the session was deleted while init was in-flight, clean it up
          // and throw so callers never receive a disconnected session.
          if (pendingDeletes.has(sessionID)) {
            pendingDeletes.delete(sessionID);
            state.sessions.delete(sessionID);
            teardownSession(session);
            throw new Error(
              `Viche: session ${sessionID} was deleted while initializing`
            );
          }
          return session;
        })
        .finally(() => {
          pendingDeletes.delete(sessionID);
          state.initializing.delete(sessionID);
        });

      state.initializing.set(sessionID, promise);
      return promise;
    },

    /**
     * Called when a new OpenCode session is created.
     *
     * Ensures the session is registered, then injects a [Viche Network
     * Connected] identity message so the LLM knows its agent ID.
     */
    async handleSessionCreated(sessionID: string): Promise<void> {
      const session = await service.ensureSessionReady(sessionID);
      await client.session.prompt({
        path: { id: sessionID },
        body: {
          noReply: true,
          parts: [
            {
              type: "text",
              text: `[Viche Network Connected] Your agent ID is ${session.agentId}. You are now registered on the Viche agent network and can receive tasks and results from other agents.`,
            },
          ],
        },
        query: { directory },
      });
    },

    /**
     * Called when an OpenCode session is deleted.
     *
     * Leaves the Phoenix Channel, disconnects the socket, and removes
     * the session from state. Safe to call on unknown session IDs.
     */
    handleSessionDeleted(sessionID: string): void {
      // If initialization is in-flight, mark for cleanup once init resolves.
      if (state.initializing.has(sessionID)) {
        pendingDeletes.add(sessionID);
        return;
      }

      const session = state.sessions.get(sessionID);
      if (session === undefined) return;

      teardownSession(session);

      state.sessions.delete(sessionID);
    },

    /**
     * Shuts down all active sessions. Called on plugin unload.
     */
    shutdown(): void {
      for (const sessionID of Array.from(state.sessions.keys())) {
        service.handleSessionDeleted(sessionID);
      }
    },
  };

  return service;
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
