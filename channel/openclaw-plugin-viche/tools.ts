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
import type { AnyAgentTool, OpenClawPluginApi } from "openclaw/plugin-sdk/plugin-entry";
import type {
  AgentInfo,
  AgentToolResult,
  DiscoverResponse,
  VicheConfig,
  VicheState,
} from "./types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Format an agent list for display in the LLM context. */
function formatAgents(agents: AgentInfo[]): string {
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

/** Build a plain-text error result for tool responses. */
function errorResult(text: string): AgentToolResult {
  return { content: [{ type: "text", text }] };
}

/** Build a plain-text success result for tool responses. */
function textResult(text: string): AgentToolResult {
  return { content: [{ type: "text", text }] };
}

/** Guard: return an error result if the Viche service is not yet connected. */
function requireConnected(state: VicheState): AgentToolResult | null {
  if (!state.agentId) {
    return errorResult(
      "Viche service is not yet connected. Wait for Gateway startup to complete and try again.",
    );
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tool registrations
// ---------------------------------------------------------------------------

/**
 * Register all three Viche tools on the plugin API.
 *
 * @param api    - The OpenClaw plugin API surface.
 * @param config - Resolved plugin config.
 * @param state  - Shared state; `state.agentId` is set by the background service.
 */
export function registerVicheTools(
  api: OpenClawPluginApi,
  config: VicheConfig,
  state: VicheState,
): void {
  // ── viche_discover ────────────────────────────────────────────────────────

  api.registerTool({
    name: "viche_discover",
    description:
      "Discover AI agents registered on the Viche network by capability. " +
      "Pass '*' to list all agents. " +
      "Returns a list of agents that match the requested capability string. " +
      "Use this before sending a message to find the target agent ID.",
    parameters: Type.Object({
      capability: Type.String({
        description:
          "Capability to search for (e.g. 'coding', 'research', 'code-review', 'testing'). Use '*' to return all agents.",
      }),
      token: Type.Optional(
        Type.String({
          description:
            "Registry token to scope discovery to a private registry. Omit for global discovery.",
        }),
      ),
    }),
    async execute(
      _toolCallId: string,
      params: { capability: string; token?: string },
      _signal?: AbortSignal,
    ): Promise<AgentToolResult> {
      const queryParams = new URLSearchParams({ capability: params.capability });
      if (params.token) queryParams.set("token", params.token);
      const url = `${config.registryUrl}/registry/discover?${queryParams.toString()}`;

      let resp: Response;
      try {
        resp = await fetch(url);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return errorResult(`Failed to reach Viche registry: ${msg}`);
      }

      if (!resp.ok) {
        return errorResult(
          `Failed to discover agents: ${resp.status} ${resp.statusText}`,
        );
      }

      let data: DiscoverResponse;
      try {
        data = (await resp.json()) as DiscoverResponse;
      } catch {
        return errorResult("Failed to parse discovery response from Viche.");
      }

      return textResult(formatAgents(data.agents ?? []));
    },
  } as unknown as AnyAgentTool);

  // ── viche_send ────────────────────────────────────────────────────────────

  api.registerTool({
    name: "viche_send",
    description:
      "Send a message to another AI agent on the Viche network. " +
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
      type: Type.Optional(
        Type.String({
          description: "Message type: 'task' (default), 'result', or 'ping'",
          default: "task",
        }),
      ),
    }),
    async execute(
      _toolCallId: string,
      params: { to: string; body: string; type?: string },
      _signal?: AbortSignal,
    ): Promise<AgentToolResult> {
      const guard = requireConnected(state);
      if (guard) return guard;

      const msgType = params.type ?? "task";

      let resp: Response;
      try {
        resp = await fetch(`${config.registryUrl}/messages/${params.to}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            from: state.agentId,
            body: params.body,
            type: msgType,
          }),
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return errorResult(`Failed to reach Viche registry: ${msg}`);
      }

      if (!resp.ok) {
        return errorResult(
          `Failed to send message: ${resp.status} ${resp.statusText}`,
        );
      }

      return textResult(
        `Message sent to ${params.to} (type: ${msgType}).`,
      );
    },
  } as unknown as AnyAgentTool);

  // ── viche_reply ───────────────────────────────────────────────────────────

  api.registerTool({
    name: "viche_reply",
    description:
      "Reply to an agent that sent you a task via the Viche network. " +
      "Sends a 'result' type message back to the originating agent. " +
      "Use the 'from' field of the received task message as the 'to' parameter.",
    parameters: Type.Object({
      to: Type.String({
        description:
          "Agent ID to reply to — copy from the 'from' field of the task message you received",
      }),
      body: Type.String({
        description: "Your result, answer, or response to send back",
      }),
    }),
    async execute(
      _toolCallId: string,
      params: { to: string; body: string },
      _signal?: AbortSignal,
    ): Promise<AgentToolResult> {
      const guard = requireConnected(state);
      if (guard) return guard;

      let resp: Response;
      try {
        resp = await fetch(`${config.registryUrl}/messages/${params.to}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            from: state.agentId,
            body: params.body,
            type: "result",
          }),
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return errorResult(`Failed to reach Viche registry: ${msg}`);
      }

      if (!resp.ok) {
        return errorResult(
          `Failed to send reply: ${resp.status} ${resp.statusText}`,
        );
      }

      return textResult(`Reply sent to ${params.to}.`);
    },
  } as unknown as AnyAgentTool);
}
