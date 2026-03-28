/**
 * Tool definitions for openclaw-plugin-viche.
 *
 * Three tools are exposed to the LLM:
 *   - viche_discover  — find agents by capability
 *   - viche_send      — send a message to another agent
 *   - viche_reply     — reply to an agent that sent a task
 *
 * Tools use direct HTTP REST calls to Viche (not the Phoenix Channel push),
 * because each tool executes in the context of an agent session while the
 * WebSocket channel is owned by the background service.
 *
 * The shape `{ name, description, parameters, execute }` matches
 * @mariozechner/pi-agent-core's `AgentTool<T, R>` contract. We cast to
 * `AnyAgentTool` as done throughout the OpenClaw extension ecosystem.
 */
import { Type } from "@sinclair/typebox";
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
/** Format an agent list for display in the LLM context. */
function formatAgents(agents) {
    if (!agents || agents.length === 0) {
        return "No agents found matching that capability.";
    }
    const lines = agents.map((a) => {
        const caps = a.capabilities?.join(", ") ?? "none";
        const name = a.name ? ` (${a.name})` : "";
        const desc = a.description ? ` — ${a.description}` : "";
        return `• ${a.id}${name} — capabilities: ${caps}${desc}`;
    });
    return `Found ${agents.length} agent(s):\n${lines.join("\n")}`;
}
/** Build a plain-text success result for tool responses. */
function textResult(text) {
    return { content: [{ type: "text", text }] };
}
/** Guard: return an error result if the Viche service is not yet connected. */
function requireConnected(state) {
    if (!state.agentId) {
        return textResult("Viche service is not yet connected. Wait for Gateway startup to complete and try again.");
    }
    return null;
}
// ---------------------------------------------------------------------------
// Tool registrations
// ---------------------------------------------------------------------------
/** Fallback session key used when no context session is available. */
const MAIN_SESSION = "agent:main:main";
/**
 * Register all three Viche tools on the plugin API using the factory pattern.
 *
 * Each tool is registered as a factory `(ctx) => tool` so that the executing
 * session's `ctx.sessionKey` can be captured at invocation time. This enables:
 *   - Correlation tracking: `viche_send` records `messageId → sessionKey` so
 *     inbound "result" replies route back to the originating session.
 *   - "most-recent" routing: `state.mostRecentSessionKey` is updated on every
 *     `viche_send` / `viche_reply` call.
 *
 * @param api    - The OpenClaw plugin API surface.
 * @param config - Resolved plugin config.
 * @param state  - Shared state; `state.agentId` is set by the background service.
 */
export function registerVicheTools(api, config, state) {
    // ── viche_discover ────────────────────────────────────────────────────────
    // Discovery does not require session context, but uses the factory pattern
    // for consistency and forward compatibility.
    api.registerTool(((_ctx) => ({
        name: "viche_discover",
        description: "Discover AI agents registered on the Viche network by capability. " +
            "Pass '*' to list all agents. " +
            "Returns a list of agents that match the requested capability string. " +
            "Use this before sending a message to find the target agent ID.",
        parameters: Type.Object({
            capability: Type.String({
                description: "Capability to search for (e.g. 'coding', 'research', 'code-review', 'testing'). Use '*' to return all agents.",
            }),
            token: Type.Optional(Type.String({
                description: "Registry token to scope discovery to a private registry. Omit for global discovery.",
            })),
        }),
        async execute(_toolCallId, params, _signal) {
            const queryParams = new URLSearchParams({ capability: params.capability });
            if (params.token)
                queryParams.set("token", params.token);
            const url = `${config.registryUrl}/registry/discover?${queryParams.toString()}`;
            let resp;
            try {
                resp = await fetch(url);
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                return textResult(`Failed to reach Viche registry: ${msg}`);
            }
            if (!resp.ok) {
                return textResult(`Failed to discover agents: ${resp.status} ${resp.statusText}`);
            }
            let data;
            try {
                data = (await resp.json());
            }
            catch {
                return textResult("Failed to parse discovery response from Viche.");
            }
            if (!Array.isArray(data.agents)) {
                return textResult("Invalid discovery response from Viche: expected 'agents' to be an array.");
            }
            return textResult(formatAgents(data.agents));
        },
    })));
    // ── viche_send ────────────────────────────────────────────────────────────
    // Captures `ctx.sessionKey` to:
    //   1. Record session activity for "most-recent" inbound routing.
    //   2. Store a correlation entry (messageId → sessionKey) so that incoming
    //      "result" replies can be routed back to this exact session.
    api.registerTool(((ctx) => {
        const sessionKey = ctx.sessionKey ?? MAIN_SESSION;
        return {
            name: "viche_send",
            description: "Send a message to another AI agent on the Viche network. " +
                "Use this to delegate tasks, ask questions, or ping other agents. " +
                "You must know the target agent ID (use viche_discover first if needed).",
            parameters: Type.Object({
                to: Type.String({
                    description: "Target agent ID (UUID format, e.g. '550e8400-e29b-41d4-a716-446655440000')",
                    pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                }),
                body: Type.String({
                    description: "Message content to send to the target agent",
                }),
                type: Type.Optional(Type.String({
                    description: "Message type: 'task' (default), 'result', or 'ping'",
                    default: "task",
                })),
            }),
            async execute(_toolCallId, params, _signal) {
                const guard = requireConnected(state);
                if (guard)
                    return guard;
                // Track session activity for "most-recent" inbound routing.
                state.mostRecentSessionKey = sessionKey;
                const msgType = params.type ?? "task";
                let resp;
                try {
                    resp = await fetch(`${config.registryUrl}/messages/${encodeURIComponent(params.to)}`, {
                        method: "POST",
                        headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({
                            from: state.agentId,
                            body: params.body,
                            type: msgType,
                        }),
                    });
                }
                catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    return textResult(`Failed to reach Viche registry: ${msg}`);
                }
                if (!resp.ok) {
                    return textResult(`Failed to send message: ${resp.status} ${resp.statusText}`);
                }
                // Record correlation so "result" replies route back to this session.
                try {
                    const data = (await resp.json());
                    if (typeof data.message_id === "string" && data.message_id.length > 0) {
                        state.correlations.set(data.message_id, {
                            sessionKey,
                            timestamp: Date.now(),
                        });
                    }
                }
                catch {
                    // Correlation tracking is best-effort; ignore parse errors.
                }
                return textResult(`Message sent to ${params.to} (type: ${msgType}).`);
            },
        };
    }));
    // ── viche_reply ───────────────────────────────────────────────────────────
    // Captures `ctx.sessionKey` to update "most-recent" session activity.
    api.registerTool(((ctx) => {
        const sessionKey = ctx.sessionKey ?? MAIN_SESSION;
        return {
            name: "viche_reply",
            description: "Reply to an agent that sent you a task via the Viche network. " +
                "Sends a 'result' type message back to the originating agent. " +
                "Use the 'from' field of the received task message as the 'to' parameter.",
            parameters: Type.Object({
                to: Type.String({
                    description: "Agent ID to reply to — copy from the 'from' field of the task message you received",
                }),
                body: Type.String({
                    description: "Your result, answer, or response to send back",
                }),
            }),
            async execute(_toolCallId, params, _signal) {
                const guard = requireConnected(state);
                if (guard)
                    return guard;
                // Track session activity for "most-recent" inbound routing.
                state.mostRecentSessionKey = sessionKey;
                let resp;
                try {
                    resp = await fetch(`${config.registryUrl}/messages/${encodeURIComponent(params.to)}`, {
                        method: "POST",
                        headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({
                            from: state.agentId,
                            body: params.body,
                            type: "result",
                        }),
                    });
                }
                catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    return textResult(`Failed to reach Viche registry: ${msg}`);
                }
                if (!resp.ok) {
                    return textResult(`Failed to send reply: ${resp.status} ${resp.statusText}`);
                }
                return textResult(`Reply sent to ${params.to}.`);
            },
        };
    }));
}
//# sourceMappingURL=tools.js.map