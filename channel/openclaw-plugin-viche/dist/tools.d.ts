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
import type { OpenClawPluginApi, VicheConfig, VicheState } from "./types.js";
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
export declare function registerVicheTools(api: OpenClawPluginApi, config: VicheConfig, state: VicheState): void;
//# sourceMappingURL=tools.d.ts.map