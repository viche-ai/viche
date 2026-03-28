/**
 * Tool definitions for opencode-plugin-viche.
 *
 * Three tools are exposed to the LLM:
 *   - viche_discover  — find agents by capability (stateless HTTP GET)
 *   - viche_send      — send a message to another agent (requires session)
 *   - viche_reply     — reply to an agent that sent a task (requires session)
 *
 * Tools use direct HTTP REST calls to Viche (not the Phoenix Channel push),
 * because each tool executes in the context of an agent session while the
 * WebSocket channel is owned by the background service.
 *
 * `createVicheTools` is a factory that accepts the resolved config, shared
 * state, and the `ensureSessionReady` dependency from the service layer.
 * The plugin entry point (Phase 5) wires these together.
 */

import { z } from "zod";
import type {
  AgentInfo,
  DiscoverResponse,
  SessionState,
  VicheConfig,
  VicheState,
} from "./types.js";

// ---------------------------------------------------------------------------
// Local types
// ---------------------------------------------------------------------------

/**
 * Tool definition shape matching the OpenCode SDK's ToolDefinition.
 *
 * `args` is a Zod raw shape (record of Zod types) — NOT a JSON Schema object.
 * OpenCode uses this shape to infer parameter types and validate inputs.
 *
 * `execute` is declared as a method (not a function property) so that each
 * tool can narrow its `args` type while still satisfying this interface
 * (TypeScript uses bivariant checking for method declarations).
 */
interface ToolDefinition {
  description: string;
  args: z.ZodRawShape;
  execute(args: Record<string, unknown>, context: { sessionID: string }): Promise<string>;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Format an agent list for display in the LLM context. */
function formatAgents(agents: AgentInfo[]): string {
  if (agents.length === 0) return "No agents found matching that capability.";
  const lines = agents.map((a) => {
    const caps = a.capabilities?.join(", ") ?? "none";
    const name = a.name ? ` (${a.name})` : "";
    const desc = a.description ? ` — ${a.description}` : "";
    return `• ${a.id}${name} — capabilities: ${caps}${desc}`;
  });
  return `Found ${agents.length} agent(s):\n${lines.join("\n")}`;
}

interface PostMessageArgs {
  registryUrl: string;
  to: string;
  from: string;
  body: string;
  type: string;
}

/**
 * Shared HTTP POST for viche_send and viche_reply.
 *
 * Returns `null` on success, or an error string on failure.
 * Never throws — callers should check the return value and return it directly.
 */
async function postMessage(args: PostMessageArgs): Promise<string | null> {
  const { registryUrl, to, from, body, type } = args;
  let resp: Response;
  try {
    resp = await fetch(`${registryUrl}/messages/${to}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ from, body, type }),
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return `Failed to reach Viche registry: ${msg}`;
  }
  if (!resp.ok) {
    return `Failed to send message: ${resp.status} ${resp.statusText}`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/**
 * Creates the three Viche tool definitions for an OpenCode plugin context.
 *
 * @param config              - Resolved plugin config.
 * @param _state              - Shared mutable state (unused here; reserved for future use).
 * @param ensureSessionReady  - Session initialisation dependency from the service layer.
 */
export function createVicheTools(
  config: VicheConfig,
  _state: VicheState,
  ensureSessionReady: (sessionID: string) => Promise<SessionState>
): Record<string, ToolDefinition> {
  // ── viche_discover ──────────────────────────────────────────────────────────

  const viche_discover: ToolDefinition = {
    description:
      "Discover AI agents registered on the Viche network by capability. " +
      "Pass '*' to list all agents. " +
      "Returns a list of agents that match the requested capability string. " +
      "Use this before sending a message to find the target agent ID.",
    args: {
      capability: z
        .string()
        .describe(
          "Capability to search for (e.g. 'coding', 'research'). Use '*' for all."
        ),
      token: z
        .string()
        .optional()
        .describe(
          "Registry token to scope discovery to a private registry. Omit for global discovery."
        ),
    },
    async execute(
      args: { capability: string; token?: string },
      _context: { sessionID: string }
    ): Promise<string> {
      const { capability, token } = args;
      let url = `${config.registryUrl}/registry/discover?capability=${encodeURIComponent(capability)}`;
      if (token) url += `&token=${encodeURIComponent(token)}`;

      let resp: Response;
      try {
        resp = await fetch(url);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return `Failed to reach Viche registry: ${msg}`;
      }

      if (!resp.ok) {
        return `Failed to discover agents: ${resp.status} ${resp.statusText}`;
      }

      let data: DiscoverResponse;
      try {
        data = (await resp.json()) as DiscoverResponse;
      } catch {
        return "Failed to parse discovery response from Viche.";
      }

      return formatAgents(data.agents ?? []);
    },
  };

  // ── viche_send ──────────────────────────────────────────────────────────────

  const viche_send: ToolDefinition = {
    description:
      "Send a message to another AI agent on the Viche network. " +
      "Use this to delegate tasks, ask questions, or ping other agents. " +
      "You must know the target agent ID (use viche_discover first if needed).",
    args: {
      to: z
        .string()
        .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
        .describe("Target agent ID (UUID, e.g. '550e8400-e29b-41d4-a716-446655440000')"),
      body: z.string().describe("Message content to send to the target agent"),
      type: z
        .string()
        .optional()
        .default("task")
        .describe("Message type: 'task' (default), 'result', or 'ping'"),
    },
    async execute(
      args: { to: string; body: string; type?: string },
      context: { sessionID: string }
    ): Promise<string> {
      let sessionState: SessionState;
      try {
        sessionState = await ensureSessionReady(context.sessionID);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return `Failed to initialise session: ${msg}`;
      }

      const { to, body } = args;
      const msgType = args.type ?? "task";

      const err = await postMessage({
        registryUrl: config.registryUrl,
        to,
        from: sessionState.agentId,
        body,
        type: msgType,
      });
      if (err !== null) return err;

      return `Message sent to ${to} (type: ${msgType}).`;
    },
  };

  // ── viche_reply ─────────────────────────────────────────────────────────────

  const viche_reply: ToolDefinition = {
    description:
      "Reply to an agent that sent you a task via the Viche network. " +
      "Sends a 'result' type message back to the originating agent. " +
      "Use the 'from' field of the received task message as the 'to' parameter.",
    args: {
      to: z
        .string()
        .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
        .describe(
          "Agent ID to reply to — copy from the 'from' field of the task message you received (UUID)"
        ),
      body: z.string().describe("Your result, answer, or response to send back"),
    },
    async execute(
      args: { to: string; body: string },
      context: { sessionID: string }
    ): Promise<string> {
      let sessionState: SessionState;
      try {
        sessionState = await ensureSessionReady(context.sessionID);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return `Failed to initialise session: ${msg}`;
      }

      const { to, body } = args;

      const err = await postMessage({
        registryUrl: config.registryUrl,
        to,
        from: sessionState.agentId,
        body,
        type: "result",
      });
      if (err !== null) return err;

      return `Reply sent to ${to}.`;
    },
  };

  return { viche_discover, viche_send, viche_reply };
}
