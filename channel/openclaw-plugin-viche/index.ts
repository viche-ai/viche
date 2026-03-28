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

import { createVicheService } from "./service.js";
import { registerVicheTools } from "./tools.js";
import { VicheConfigSchema } from "./types.js";
import type { VicheConfig, VicheState, OpenClawPluginApi } from "./types.js";

export default {
  id: "viche",
  name: "Viche Agent Network",
  description:
    "Discover and message AI agents across the Viche network. " +
    "Registers this OpenClaw instance as a Viche agent on startup and exposes " +
    "viche_discover, viche_send, and viche_reply tools to the LLM.",
  configSchema: VicheConfigSchema,

  register(api: unknown) {
    const typedApi = api as unknown as OpenClawPluginApi;

    // Parse and normalise the raw plugin config, applying defaults.
    const rawConfig = typedApi.pluginConfig ?? {};
    const parseResult = VicheConfigSchema.safeParse(rawConfig);

    if (!parseResult.success) {
      const issues = parseResult.error.issues
        .map((i) => `  ${i.path.join(".") || "<root>"}: ${i.message}`)
        .join("\n");
      throw new Error(`Viche plugin config is invalid:\n${issues}`);
    }

    const config: VicheConfig = parseResult.data;

    // Shared state: written by service on startup, read by tool handlers.
    const state: VicheState = {
      agentId: null,
      correlations: new Map(),
      mostRecentSessionKey: null,
    };

    // Background service — registration + WebSocket lifecycle.
    const runtime = typedApi.runtime;
    const openclawConfig = typedApi.config;
    typedApi.registerService(createVicheService(config, state, runtime, openclawConfig));

    // Agent-callable tools.
    registerVicheTools(typedApi, config, state);
  },
};
