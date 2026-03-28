/**
 * Shared types and config schema for openclaw-plugin-viche.
 *
 * VicheConfigSchema implements OpenClawPluginConfigSchema (safeParse + jsonSchema).
 * TypeBox TObject is a plain JSON Schema object and does NOT implement
 * OpenClawPluginConfigSchema, so we build the schema manually.
 */

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/** Plugin configuration provided via openclaw.json `plugins.viche.config`. */
export interface VicheConfig {
  /** Viche registry base URL. Default: "http://localhost:4000" */
  registryUrl: string;
  /** Agent capabilities to register. Default: ["coding"] */
  capabilities: string[];
  /** Optional human-readable agent name. */
  agentName?: string;
  /** Optional agent description. */
  description?: string;
}

// ---------------------------------------------------------------------------
// Runtime type alias
// ---------------------------------------------------------------------------

/**
 * Alias for the OpenClaw PluginRuntime object passed to the service.
 * Typed as `any` to avoid importing the full SDK runtime type.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type PluginRuntime = any;

/** Defaults applied when config fields are omitted. */
const CONFIG_DEFAULTS: { registryUrl: string; capabilities: string[] } = {
  registryUrl: "http://localhost:4000",
  capabilities: ["coding"],
};

type Issue = { path: Array<string | number>; message: string };
type SafeParseResult =
  | { success: true; data: VicheConfig }
  | { success: false; error: { issues: Issue[] } };

function issue(path: Array<string | number>, message: string): SafeParseResult {
  return { success: false, error: { issues: [{ path, message }] } };
}

/**
 * OpenClawPluginConfigSchema implementation for VicheConfig.
 * Validates, normalises, and applies defaults to raw plugin config values.
 */
export const VicheConfigSchema = {
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
        !raw.capabilities.every((c) => typeof c === "string")
      ) {
        return issue(["capabilities"], "must be an array of strings");
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

    return { success: true, data: normalized };
  },

  jsonSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      registryUrl: {
        type: "string",
        default: "http://localhost:4000",
        description: "Viche registry base URL",
      },
      capabilities: {
        type: "array",
        items: { type: "string" },
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
    },
  },
} as const;

// ---------------------------------------------------------------------------
// Shared runtime state
// ---------------------------------------------------------------------------

/**
 * Mutable state shared between the background service and the tool handlers.
 * The service sets `agentId` on successful registration and clears it on stop.
 */
export interface VicheState {
  agentId: string | null;
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

export interface RegisterResponse {
  id: string;
}

export interface InboundMessagePayload {
  id: string;
  from: string;
  body: string;
  type: string;
}
