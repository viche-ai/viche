/**
 * Shared types and config schema for openclaw-plugin-viche.
 *
 * VicheConfigSchema implements OpenClawPluginConfigSchema (safeParse + jsonSchema).
 * TypeBox TObject is a plain JSON Schema object and does NOT implement
 * OpenClawPluginConfigSchema, so we build the schema manually.
 */
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
export type AnyAgentTool = any;
/**
 * Config schema interface required by OpenClaw plugins.
 * Must provide `safeParse` for validation and `jsonSchema` for UI generation.
 */
export interface OpenClawPluginConfigSchema<T = unknown> {
    safeParse(value: unknown): {
        success: true;
        data: T;
    } | {
        success: false;
        error: {
            issues: Array<{
                path: Array<string | number>;
                message: string;
            }>;
        };
    };
    jsonSchema: Record<string, unknown>;
}
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
        }): Promise<{
            runId: string;
        }>;
    };
}
/**
 * OpenClawPluginConfigSchema implementation for VicheConfig.
 * Validates, normalises, and applies defaults to raw plugin config values.
 */
export declare const VicheConfigSchema: OpenClawPluginConfigSchema<VicheConfig>;
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
    correlations: Map<string, CorrelationEntry>;
    mostRecentSessionKey: string | null;
}
export type AgentToolResult = {
    content: Array<{
        type: string;
        text: string;
    }>;
    details?: unknown;
};
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
//# sourceMappingURL=types.d.ts.map