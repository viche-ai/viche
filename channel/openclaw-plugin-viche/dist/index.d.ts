/**
 * openclaw-plugin-viche — Plugin entry point.
 *
 * Registers:
 *   1. A background service (`viche-bridge`) that maintains the agent's
 *      registration in the Viche registry and its Phoenix Channel WebSocket
 *      connection for real-time inbound message delivery.
 *   2. Three agent tools: `viche_discover`, `viche_send`, `viche_reply`.
 *
 * Config is read from `openclaw.json` under `plugins.viche.config`.
 * See `types.VicheConfig` for the full schema with defaults.
 */
import type { VicheConfig } from "./types.js";
declare const _default: {
    id: string;
    name: string;
    description: string;
    configSchema: import("./types.js").OpenClawPluginConfigSchema<VicheConfig>;
    register(api: unknown): void;
};
export default _default;
//# sourceMappingURL=index.d.ts.map