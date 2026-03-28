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
import type { AgentInfo, OpenClawPluginService, PluginRuntime, VicheConfig, VicheState } from "./types.js";
/**
 * Returns an OpenClawPluginService that manages the Viche WebSocket lifecycle.
 *
 * @param config        - Resolved plugin config (from types.VicheConfig).
 * @param state         - Shared mutable state object written by the service and
 *                        read by the tool handlers.
 * @param runtime       - OpenClaw PluginRuntime for spawning subagent sessions.
 * @param _openclawConfig - Full OpenClaw config (reserved for future use).
 */
export declare function createVicheService(config: VicheConfig, state: VicheState, runtime: PluginRuntime, _openclawConfig: unknown): OpenClawPluginService;
export { type AgentInfo };
//# sourceMappingURL=service.d.ts.map