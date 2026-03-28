/**
 * Shared type definitions for opencode-plugin-viche.
 *
 * These are compile-time interfaces only — no runtime validation here.
 * Validation and defaults live in config.ts (Phase 2).
 */

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/** Plugin configuration provided via opencode plugin config. */
export interface VicheConfig {
  /** Viche registry base URL. Default: "http://localhost:4000" */
  registryUrl: string;
  /** Agent capabilities to register. Default: ["coding"] */
  capabilities: string[];
  /** Optional human-readable agent name. */
  agentName?: string;
  /** Optional agent description. */
  description?: string;
  /** Registry token for private registry. Auto-generated if not set. */
  registryToken?: string;
}

// ---------------------------------------------------------------------------
// Per-session state
// ---------------------------------------------------------------------------

/** State tracked for a single OpenCode session connected to Viche. */
export interface SessionState {
  /** Registered Viche agent ID (UUID). */
  agentId: string;
  /** Phoenix Socket instance (typed as any to avoid import coupling). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  socket: any;
  /** Phoenix Channel instance joined on "agent:{agentId}". */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  channel: any;
}

// ---------------------------------------------------------------------------
// Global plugin state
// ---------------------------------------------------------------------------

/**
 * Mutable state shared between the background service and tool handlers.
 * Keyed by OpenCode session ID.
 */
export interface VicheState {
  /** Active sessions: sessionId → SessionState. */
  sessions: Map<string, SessionState>;
  /**
   * In-flight initializations: sessionId → Promise<SessionState>.
   * Used to deduplicate concurrent init calls for the same session.
   */
  initializing: Map<string, Promise<SessionState>>;
}

// ---------------------------------------------------------------------------
// Viche API response shapes
// ---------------------------------------------------------------------------

/** Response body from POST /api/agents (agent registration). */
export interface RegisterResponse {
  id: string;
}

/** Single agent entry returned by discovery. */
export interface AgentInfo {
  id: string;
  name?: string;
  capabilities?: string[];
  description?: string;
}

/** Response body from GET /api/agents?capability=... */
export interface DiscoverResponse {
  agents: AgentInfo[];
}

/** Payload pushed over the Phoenix Channel when a message arrives. */
export interface InboundMessagePayload {
  id: string;
  from: string;
  body: string;
  type: string;
}
