/**
 * Shared types and config schema for openclaw-plugin-viche.
 *
 * VicheConfigSchema implements OpenClawPluginConfigSchema (safeParse + jsonSchema).
 * TypeBox TObject is a plain JSON Schema object and does NOT implement
 * OpenClawPluginConfigSchema, so we build the schema manually.
 */

// ---------------------------------------------------------------------------
// OpenClaw Plugin SDK types (local declarations for backward compatibility)
// ---------------------------------------------------------------------------

/**
 * Minimal subset of OpenClawPluginApi used by the Viche plugin.
 * Declared locally to avoid importing from openclaw/plugin-sdk.
 */
export interface OpenClawPluginApi {
  /** Raw plugin config from openclaw.json (before schema validation). */
  pluginConfig?: Record<string, unknown>;
  /** Register a background service (lifecycle: start/stop). */
  registerService(service: OpenClawPluginService): void;
  /** Register an agent tool (factory pattern: (ctx) => tool). */
  registerTool(factory: (ctx: OpenClawPluginToolContext) => AnyAgentTool): void;
  /** OpenClaw runtime APIs (subagent spawning, etc). */
  runtime: PluginRuntime;
  /** Full OpenClaw config object. */
  config: unknown;
}

/**
 * Background service interface for OpenClaw plugins.
 * Services run for the lifetime of the Gateway and manage long-lived resources.
 */
export interface OpenClawPluginService {
  /** Unique service ID (used in logs). */
  id: string;
  /** Called when the Gateway starts. Throw to prevent startup. */
  start(ctx: OpenClawPluginServiceContext): Promise<void>;
  /** Called when the Gateway stops. Clean up resources here. */
  stop(ctx: OpenClawPluginServiceContext): Promise<void>;
}

/**
 * Context passed to service start/stop methods.
 */
export interface OpenClawPluginServiceContext {
  /** Logger instance for this service. */
  logger: PluginLogger;
}

/**
 * Logger interface provided to plugin services.
 */
export interface PluginLogger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

/**
 * Context passed to tool factory functions.
 * Contains the session key of the agent invoking the tool.
 */
export interface OpenClawPluginToolContext {
  /** Session key (e.g. "agent:main:main") of the invoking agent. */
  sessionKey?: string;
}

/**
 * Agent tool type (opaque — cast through `unknown` to avoid deep type dependencies).
 * The actual shape is defined by @mariozechner/pi-agent-core's AgentTool<T, R>.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnyAgentTool = any;

/**
 * Config schema interface required by OpenClaw plugins.
 * Must provide `safeParse` for validation and `jsonSchema` for UI generation.
 */
export interface OpenClawPluginConfigSchema<T = unknown> {
  safeParse(value: unknown): { success: true; data: T } | { success: false; error: { issues: Array<{ path: Array<string | number>; message: string }> } };
  jsonSchema: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/** Plugin configuration provided via openclaw.json `plugins.viche.config`. */
export interface VicheConfig {
  /** Viche registry base URL. Default: "https://viche.ai" */
  registryUrl: string;
  /** Agent capabilities to register. Default: ["coding"] */
  capabilities: string[];
  /** Optional human-readable agent name. */
  agentName?: string;
  /** Optional agent description. */
  description?: string;
  /** Optional registry tokens for joining private registries. */
  registries?: string[];
  /**
   * How to route unsolicited inbound "task" messages (and "result" messages
   * when correlation cannot be resolved).
   *
   * - "most-recent" — route to the session that most recently called viche_send or viche_reply (default)
   * - "main"        — always route to `agent:main:main`
   */
  defaultInboundSession?: "most-recent" | "main";
}

// ---------------------------------------------------------------------------
// Runtime type alias
// ---------------------------------------------------------------------------

/**
 * OpenClaw PluginRuntime object passed to services.
 * Provides access to subagent spawning via `subagent.run`.
 */
export interface PluginRuntime {
  subagent: {
    run(params: {
      sessionKey: string;
      message: string;
      deliver: boolean;
      idempotencyKey: string;
    }): Promise<{ runId: string }>;
  };
}

/** Defaults applied when config fields are omitted. */
const CONFIG_DEFAULTS: { registryUrl: string; capabilities: string[] } = {
  registryUrl: "https://viche.ai",
  capabilities: ["coding"],
};

type Issue = { path: Array<string | number>; message: string };
type SafeParseResult =
  | { success: true; data: VicheConfig }
  | { success: false; error: { issues: Issue[] } };

const REGISTRY_TOKEN_PATTERN = /^[a-zA-Z0-9._-]+$/;
const REGISTRY_TOKEN_MIN_LENGTH = 4;
const REGISTRY_TOKEN_MAX_LENGTH = 256;

function issue(path: Array<string | number>, message: string): SafeParseResult {
  return { success: false, error: { issues: [{ path, message }] } };
}

function validRegistryToken(token: string): boolean {
  return (
    token.length >= REGISTRY_TOKEN_MIN_LENGTH &&
    token.length <= REGISTRY_TOKEN_MAX_LENGTH &&
    REGISTRY_TOKEN_PATTERN.test(token)
  );
}

/**
 * OpenClawPluginConfigSchema implementation for VicheConfig.
 * Validates, normalises, and applies defaults to raw plugin config values.
 */
export const VicheConfigSchema: OpenClawPluginConfigSchema<VicheConfig> = {
  safeParse(value: unknown): SafeParseResult {
    // Allow undefined / null → full defaults
    if (value === undefined || value === null) {
      return { success: true, data: { ...CONFIG_DEFAULTS } };
    }

    if (typeof value !== "object" || Array.isArray(value)) {
      return issue([], "plugin config must be an object");
    }

    const raw = value as Record<string, unknown>;

    // registryUrl
    if (raw.registryUrl !== undefined && typeof raw.registryUrl !== "string") {
      return issue(["registryUrl"], "must be a string");
    }

    // capabilities
    if (raw.capabilities !== undefined) {
      if (
        !Array.isArray(raw.capabilities) ||
        raw.capabilities.length === 0 ||
        !raw.capabilities.every((c) => typeof c === "string")
      ) {
        return issue(["capabilities"], "must be a non-empty array of strings");
      }
    }

    // agentName
    if (raw.agentName !== undefined && typeof raw.agentName !== "string") {
      return issue(["agentName"], "must be a string");
    }

    // description
    if (raw.description !== undefined && typeof raw.description !== "string") {
      return issue(["description"], "must be a string");
    }

    // registries (new array form)
    if (raw.registries !== undefined) {
      if (
        !Array.isArray(raw.registries) ||
        !raw.registries.every((r) => typeof r === "string" && validRegistryToken(r))
      ) {
        return issue(
          ["registries"],
          "must be an array of valid registry tokens (4-256 chars, [a-zA-Z0-9._-])",
        );
      }
    }

    // registryToken (legacy string — converted to single-element array)
    if (raw.registryToken !== undefined && typeof raw.registryToken !== "string") {
      return issue(["registryToken"], "must be a string");
    }

    if (
      typeof raw.registryToken === "string" &&
      raw.registryToken.length > 0 &&
      !validRegistryToken(raw.registryToken)
    ) {
      return issue(
        ["registryToken"],
        "must be a valid registry token (4-256 chars, [a-zA-Z0-9._-])",
      );
    }

    // defaultInboundSession
    if (
      raw.defaultInboundSession !== undefined &&
      raw.defaultInboundSession !== "most-recent" &&
      raw.defaultInboundSession !== "main"
    ) {
      return issue(["defaultInboundSession"], 'must be "most-recent" or "main"');
    }

    const normalized: VicheConfig = {
      registryUrl:
        typeof raw.registryUrl === "string"
          ? raw.registryUrl
          : CONFIG_DEFAULTS.registryUrl,
      capabilities: Array.isArray(raw.capabilities)
        ? (raw.capabilities as string[])
        : CONFIG_DEFAULTS.capabilities,
    };

    // Only assign optional string properties when present to satisfy exactOptionalPropertyTypes.
    if (typeof raw.agentName === "string") normalized.agentName = raw.agentName;
    if (typeof raw.description === "string") normalized.description = raw.description;

    // Resolve registries: prefer `registries` array; fall back to legacy `registryToken` string.
    if (Array.isArray(raw.registries) && raw.registries.length > 0) {
      normalized.registries = raw.registries as string[];
    } else if (typeof raw.registryToken === "string" && raw.registryToken.length > 0) {
      normalized.registries = [raw.registryToken];
    }

    // defaultInboundSession
    if (
      raw.defaultInboundSession === "most-recent" ||
      raw.defaultInboundSession === "main"
    ) {
      normalized.defaultInboundSession = raw.defaultInboundSession;
    }

    return { success: true, data: normalized };
  },

  jsonSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      registryUrl: {
        type: "string",
        default: "https://viche.ai",
        description: "Viche registry base URL",
      },
      capabilities: {
        type: "array",
        items: { type: "string" },
        minItems: 1,
        default: ["coding"],
        description: "Capability strings this agent publishes to the Viche registry",
      },
      agentName: {
        type: "string",
        description: "Human-readable agent name shown in discovery results",
      },
      description: {
        type: "string",
        description: "Short description of this agent",
      },
      registries: {
        type: "array",
        items: {
          type: "string",
          minLength: REGISTRY_TOKEN_MIN_LENGTH,
          maxLength: REGISTRY_TOKEN_MAX_LENGTH,
          pattern: REGISTRY_TOKEN_PATTERN.source,
        },
        description: "Registry tokens to join one or more private registries for scoped discovery and messaging",
      },
      registryToken: {
        type: "string",
        minLength: REGISTRY_TOKEN_MIN_LENGTH,
        maxLength: REGISTRY_TOKEN_MAX_LENGTH,
        pattern: REGISTRY_TOKEN_PATTERN.source,
        description: "Legacy: single registry token (converted to registries array). Use registries instead.",
      },
      defaultInboundSession: {
        type: "string",
        enum: ["most-recent", "main"],
        default: "most-recent",
        description:
          "How to route unsolicited inbound messages. " +
          '"most-recent" routes to the session that most recently sent a Viche message (default). ' +
          '"main" always routes to agent:main:main.',
      },
    },
  },
};

// ---------------------------------------------------------------------------
// Shared runtime state
// ---------------------------------------------------------------------------

/**
 * A recorded outbound message sent via viche_send.
 * Used to route incoming "result" replies back to the originating session.
 */
export interface CorrelationEntry {
  /** OpenClaw session key that originated the send (e.g. "agent:main:main"). */
  sessionKey: string;
  /** Unix ms timestamp of when the message was sent (used for TTL expiry). */
  timestamp: number;
}

/**
 * Mutable state shared between the background service and the tool handlers.
 *
 * - `agentId`              — set by the service on successful registration; null when stopped.
 * - `correlations`         — maps outbound messageId → originating sessionKey so that
 *                            "result" replies can be routed back to the correct session.
 * - `mostRecentSessionKey` — tracks the session that last called viche_send / viche_reply;
 *                            used by `defaultInboundSession: "most-recent"` routing.
 */
export interface VicheState {
  agentId: string | null;
  channel: VicheChannel | null;
  correlations: Map<string, CorrelationEntry>;
  mostRecentSessionKey: string | null;
}

export interface VicheChannelPush {
  receive(status: "ok", callback: (response: unknown) => void): VicheChannelPush;
  receive(status: "error", callback: (response: unknown) => void): VicheChannelPush;
  receive(status: "timeout", callback: () => void): VicheChannelPush;
}

export interface VicheChannel {
  push(event: string, payload: Record<string, unknown>): VicheChannelPush;
}

// ---------------------------------------------------------------------------
// Agent tool result shape (matches @mariozechner/pi-agent-core AgentToolResult)
// ---------------------------------------------------------------------------

export type AgentToolResult = {
  content: Array<{ type: string; text: string }>;
  details?: unknown;
};

// ---------------------------------------------------------------------------
// Viche API response shapes
// ---------------------------------------------------------------------------

export interface AgentInfo {
  id: string;
  name?: string;
  capabilities?: string[];
  description?: string;
}

export interface DiscoverResponse {
  agents: AgentInfo[];
}

export interface InboundMessagePayload {
  id: string;
  from: string;
  body: string;
  type: string;
  /**
   * Optional: ID of the outbound message this is replying to.
   * Present when the Viche server populates reply correlation.
   * Used to route "result" messages back to the originating session.
   */
  replyTo?: string;
}

/** Response body from POST /messages/:agentId (Viche send endpoint). */
export interface SendMessageResponse {
  message_id: string;
}
