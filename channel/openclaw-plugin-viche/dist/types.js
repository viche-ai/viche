/**
 * Shared types and config schema for openclaw-plugin-viche.
 *
 * VicheConfigSchema implements OpenClawPluginConfigSchema (safeParse + jsonSchema).
 * TypeBox TObject is a plain JSON Schema object and does NOT implement
 * OpenClawPluginConfigSchema, so we build the schema manually.
 */
/** Defaults applied when config fields are omitted. */
const CONFIG_DEFAULTS = {
    registryUrl: "https://viche.ai",
    capabilities: ["coding"],
};
/**
 * Valid registry token pattern — must match the server-side rule in AGENTS.md.
 * Accepts 1–256 chars: alphanumeric, `.`, `_`, `-`.
 * Rejects empty strings, whitespace-only strings, and strings containing spaces.
 */
const REGISTRY_TOKEN_RE = /^[a-zA-Z0-9._-]+$/;
function issue(path, message) {
    return { success: false, error: { issues: [{ path, message }] } };
}
/**
 * OpenClawPluginConfigSchema implementation for VicheConfig.
 * Validates, normalises, and applies defaults to raw plugin config values.
 */
export const VicheConfigSchema = {
    safeParse(value) {
        // Allow undefined / null → full defaults with auto-generated private registry token
        if (value === undefined || value === null) {
            return { success: true, data: { ...CONFIG_DEFAULTS, registries: [crypto.randomUUID()] } };
        }
        if (typeof value !== "object" || Array.isArray(value)) {
            return issue([], "plugin config must be an object");
        }
        const raw = value;
        // registryUrl
        if (raw.registryUrl !== undefined && typeof raw.registryUrl !== "string") {
            return issue(["registryUrl"], "must be a string");
        }
        // capabilities
        if (raw.capabilities !== undefined) {
            if (!Array.isArray(raw.capabilities) ||
                !raw.capabilities.every((c) => typeof c === "string")) {
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
        // registries (new array form)
        if (raw.registries !== undefined) {
            if (!Array.isArray(raw.registries)) {
                return issue(["registries"], "must be an array of strings");
            }
            for (let i = 0; i < raw.registries.length; i++) {
                const r = raw.registries[i];
                if (typeof r !== "string") {
                    return issue(["registries", i], "must be a string");
                }
                if (!REGISTRY_TOKEN_RE.test(r)) {
                    return issue(["registries", i], 'must match ^[a-zA-Z0-9._-]+$ (no spaces or whitespace allowed)');
                }
            }
        }
        // registryToken (legacy string — converted to single-element array)
        if (raw.registryToken !== undefined) {
            if (typeof raw.registryToken !== "string") {
                return issue(["registryToken"], "must be a string");
            }
            // Non-empty value must satisfy the token format (empty string → treated as "not provided")
            if (raw.registryToken.length > 0 && !REGISTRY_TOKEN_RE.test(raw.registryToken)) {
                return issue(["registryToken"], 'must match ^[a-zA-Z0-9._-]+$ (no spaces or whitespace allowed)');
            }
        }
        // defaultInboundSession
        if (raw.defaultInboundSession !== undefined &&
            raw.defaultInboundSession !== "most-recent" &&
            raw.defaultInboundSession !== "main") {
            return issue(["defaultInboundSession"], 'must be "most-recent" or "main"');
        }
        const normalized = {
            registryUrl: typeof raw.registryUrl === "string"
                ? raw.registryUrl
                : CONFIG_DEFAULTS.registryUrl,
            capabilities: Array.isArray(raw.capabilities)
                ? raw.capabilities
                : CONFIG_DEFAULTS.capabilities,
        };
        // Only assign optional string properties when present to satisfy exactOptionalPropertyTypes.
        if (typeof raw.agentName === "string")
            normalized.agentName = raw.agentName;
        if (typeof raw.description === "string")
            normalized.description = raw.description;
        // Resolve registries: prefer `registries` array; fall back to legacy `registryToken` string.
        // When neither is provided (or both are effectively empty), auto-generate a private UUID token
        // so the server receives an explicit non-"global" token instead of silently joining "global".
        if (Array.isArray(raw.registries) && raw.registries.length > 0) {
            normalized.registries = raw.registries;
        }
        else if (typeof raw.registryToken === "string" && raw.registryToken.length > 0) {
            normalized.registries = [raw.registryToken];
        }
        else {
            normalized.registries = [crypto.randomUUID()];
        }
        // defaultInboundSession
        if (raw.defaultInboundSession === "most-recent" ||
            raw.defaultInboundSession === "main") {
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
                items: { type: "string" },
                description: "Registry tokens to join one or more private registries for scoped discovery and messaging",
            },
            registryToken: {
                type: "string",
                description: "Legacy: single registry token (converted to registries array). Use registries instead.",
            },
            defaultInboundSession: {
                type: "string",
                enum: ["most-recent", "main"],
                default: "most-recent",
                description: "How to route unsolicited inbound messages. " +
                    '"most-recent" routes to the session that most recently sent a Viche message (default). ' +
                    '"main" always routes to agent:main:main.',
            },
        },
    },
};
//# sourceMappingURL=types.js.map