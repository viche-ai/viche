/**
 * Tool definitions for opencode-plugin-viche.
 *
 * Three tools are exposed to the LLM:
 *   - viche_discover  — find agents by capability (Phoenix Channel push)
 *   - viche_send      — send a message to another agent (requires session)
 *   - viche_reply     — reply to an agent that sent a task (requires session)
 *
 * Tools use Phoenix Channel pushes via the per-session WebSocket channel.
 * Registration remains HTTP in the service layer (before WebSocket connect).
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

interface ChannelPush {
  receive(
    status: "ok" | "error" | "timeout",
    callback: (resp?: unknown) => void
  ): ChannelPush;
}

interface PushResult<T> {
  ok: boolean;
  payload?: T;
  error?: string;
}

const AgentInfoSchema = z.object({
  id: z.string(),
  name: z.string().optional(),
  capabilities: z.array(z.string()).optional(),
  description: z.string().optional(),
});

const UuidV4LikeSchema = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);

const DiscoverResponseSchema = z.object({
  agents: z.array(AgentInfoSchema),
});

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

/**
 * Format token-scoped discovery results without exposing human labels.
 *
 * This avoids surfacing potentially cross-registry names/descriptions if the
 * backend ever returns a mis-scoped payload.
 */
function formatScopedAgents(agents: AgentInfo[]): string {
  if (agents.length === 0) return "No agents found matching that capability.";
  const lines = agents.map((a, index) => {
    const caps = a.capabilities?.join(", ") ?? "none";
    return `• agent #${index + 1} — capabilities: ${caps}`;
  });
  return `Found ${agents.length} agent(s):\n${lines.join("\n")}`;
}

interface PostMessageArgs {
  channel: { push: (event: string, payload: Record<string, unknown>) => ChannelPush };
  to: string;
  body: string;
  type: string;
}

const MessageAckSchema = z.object({
  message_id: z
    .string()
    .min(1)
    .regex(/^msg-/),
});

/**
 * Shared Phoenix Channel push for viche_send and viche_reply.
 *
 * Never throws; returns a structured result for callers to format.
 */
async function postMessage(
  args: PostMessageArgs
): Promise<PushResult<{ message_id: string }>> {
  const { channel, to, body, type } = args;
  const result = await pushWithAck<{ message_id?: string }>(channel, "send_message", {
    to,
    body,
    type,
  });

  if (!result.ok) {
    return { ok: false, error: result.error ?? "unknown channel error" };
  }

  const parsedAck = MessageAckSchema.safeParse(result.payload);
  if (!parsedAck.success) {
    return { ok: false, error: "missing message_id in channel ack" };
  }

  return { ok: true, payload: parsedAck.data };
}

function safeErrorMessage(payload: unknown, fallback: string): string {
  if (payload && typeof payload === "object") {
    const maybeMessage = (payload as { message?: unknown }).message;
    if (typeof maybeMessage === "string" && maybeMessage.length > 0) {
      return maybeMessage;
    }
    const maybeError = (payload as { error?: unknown }).error;
    if (typeof maybeError === "string" && maybeError.length > 0) {
      return maybeError;
    }
  }
  return fallback;
}

async function pushWithAck<T>(
  channel: { push: (event: string, payload: Record<string, unknown>) => ChannelPush },
  event: string,
  payload: Record<string, unknown>
): Promise<PushResult<T>> {
  return await new Promise<PushResult<T>>((resolve) => {
    let settled = false;
    const settle = (result: PushResult<T>) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    try {
      channel
        .push(event, payload)
        .receive("ok", (resp?: unknown) => {
          settle({ ok: true, payload: resp as T });
        })
        .receive("error", (resp?: unknown) => {
          const msg = safeErrorMessage(resp, `Channel error during ${event}`);
          settle({ ok: false, error: msg });
        })
        .receive("timeout", () => {
          settle({ ok: false, error: `Channel timeout during ${event}` });
        });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      settle({ ok: false, error: msg });
    }
  });
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
  const defaultRegistry = config.registries?.[0] ?? "global";

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
      context: { sessionID: string }
    ): Promise<string> {
      const { capability, token } = args;
      let sessionState: SessionState;
      try {
        sessionState = await ensureSessionReady(context.sessionID);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return `Failed to initialise session: ${msg}`;
      }

      const registry = token ?? defaultRegistry;

      const result = await pushWithAck<DiscoverResponse>(
        sessionState.channel,
        "discover",
        {
          capability,
          registry,
        }
      );

      if (!result.ok) {
        return `Failed to discover agents: ${result.error ?? "unknown channel error"}`;
      }

      const parsed = DiscoverResponseSchema.safeParse(result.payload);
      if (!parsed.success) return "Failed to parse discovery response from Viche.";

      const scopedAgents =
        token
          ? parsed.data.agents.filter((agent) => UuidV4LikeSchema.safeParse(agent.id).success)
          : parsed.data.agents;

      return token ? formatScopedAgents(scopedAgents as AgentInfo[]) : formatAgents(scopedAgents as AgentInfo[]);
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

      const result = await postMessage({
        channel: sessionState.channel,
        to,
        body,
        type: msgType,
      });
      if (!result.ok) {
        return `Failed to send message: ${result.error ?? "unknown channel error"}`;
      }

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

      const result = await postMessage({
        channel: sessionState.channel,
        to,
        body,
        type: "result",
      });
      if (!result.ok) {
        return `Failed to send reply: ${result.error ?? "unknown channel error"}`;
      }

      return `Reply sent to ${to}.`;
    },
  };

  return { viche_discover, viche_send, viche_reply };
}
