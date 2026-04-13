/**
 * Tool definitions for openclaw-plugin-viche.
 *
 * Eight tools are exposed to the LLM:
 *   - viche_discover  — find agents by capability
 *   - viche_send      — send a message to another agent
 *   - viche_reply     — reply to an agent that sent a task
 *   - viche_broadcast  — broadcast a message to a registry
 *   - viche_leave_registry      — leave one/all registries
 *   - viche_join_registry       — join a registry dynamically
 *   - viche_list_my_registries  — list registries this agent has joined
 *   - viche_whoami              — return this agent's own ID
 *
 * Tools send Phoenix Channel events through the shared channel reference
 * maintained by the background service.
 *
 * The shape `{ name, description, parameters, execute }` matches
 * @mariozechner/pi-agent-core's `AgentTool<T, R>` contract. We cast to
 * `AnyAgentTool` as done throughout the OpenClaw extension ecosystem.
 */

import { Type } from "@sinclair/typebox";
import type {
  AgentInfo,
  AgentToolResult,
  AnyAgentTool,
  DiscoverResponse,
  OpenClawPluginApi,
  OpenClawPluginToolContext,
  SendMessageResponse,
  VicheConfig,
  VicheChannel,
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

/** Build a plain-text success result for tool responses. */
function textResult(text: string): AgentToolResult {
  return { content: [{ type: "text", text }] };
}

/** Guard: return an error result if the Viche service is not yet connected. */
function requireConnected(state: VicheState): AgentToolResult | null {
  if (!state.agentId || !state.channel) {
    return textResult(
      "Viche service is not yet connected. Wait for Gateway startup to complete and try again.",
    );
  }
  return null;
}

function describeChannelError(response: unknown): string {
  if (response && typeof response === "object") {
    const record = response as Record<string, unknown>;
    if (typeof record.message === "string") return record.message;
    if (typeof record.error === "string") return record.error;
  }
  return typeof response === "string" ? response : JSON.stringify(response);
}

function validateAgentEntry(entry: unknown): entry is AgentInfo {
  if (!entry || typeof entry !== "object") return false;

  const candidate = entry as Record<string, unknown>;

  if (typeof candidate.id !== "string" || candidate.id.length === 0) return false;
  if (candidate.name !== undefined && typeof candidate.name !== "string") return false;
  if (
    !Array.isArray(candidate.capabilities) ||
    !candidate.capabilities.every((cap) => typeof cap === "string")
  ) {
    return false;
  }

  if (
    candidate.description !== undefined &&
    typeof candidate.description !== "string"
  ) {
    return false;
  }

  return true;
}

const UUID_V4_LIKE_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PROTOCOL_MESSAGE_TYPES = ["task", "result", "ping"] as const;

const MESSAGE_ID_REGEX =
  /^msg-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isUuidLike(value: unknown): value is string {
  return typeof value === "string" && UUID_V4_LIKE_REGEX.test(value);
}

function getMessageId(response: unknown): string | null {
  if (!response || typeof response !== "object") return null;

  const messageId = (response as Record<string, unknown>).message_id;
  return typeof messageId === "string" && MESSAGE_ID_REGEX.test(messageId)
    ? messageId
    : null;
}

function validProtocolMessageType(type: string): boolean {
  return PROTOCOL_MESSAGE_TYPES.includes(type as (typeof PROTOCOL_MESSAGE_TYPES)[number]);
}

function pushChannel(
  channel: VicheChannel,
  event: string,
  payload: Record<string, unknown>,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    channel
      .push(event, payload)
      .receive("ok", (resp: unknown) => resolve(resp))
      .receive("error", (resp: unknown) =>
        reject(new Error(describeChannelError(resp))),
      )
      .receive("timeout", () => reject(new Error("request timed out")));
  });
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
export function registerVicheTools(
  api: OpenClawPluginApi,
  config: VicheConfig,
  state: VicheState,
): void {
  // ── viche_discover ────────────────────────────────────────────────────────
  // Discovery does not require session context, but uses the factory pattern
  // for consistency and forward compatibility.

  api.registerTool(
    ((_ctx: OpenClawPluginToolContext) => ({
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
        const guard = requireConnected(state);
        if (guard) return guard;

        const payload: Record<string, unknown> = { capability: params.capability };
        const registryToken = params.token ?? config.registries?.[0];
        if (registryToken) payload.registry = registryToken;

        let response: unknown;
        try {
          response = await pushChannel(state.channel!, "discover", payload);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          return textResult(`Failed to discover agents: ${msg}`);
        }

        const data = response as DiscoverResponse;

        if (!Array.isArray(data.agents)) {
          return textResult(
            "Invalid discovery response from Viche: expected 'agents' to be an array.",
          );
        }

        if (!data.agents.every((agent) => validateAgentEntry(agent))) {
          return textResult(
            "Invalid discovery response from Viche: expected each agent to include valid id, optional name, and capabilities.",
          );
        }

        const visibleAgents: AgentInfo[] = registryToken
          ? data.agents
              .filter((agent) => isUuidLike(agent.id))
              .map((agent) => ({
              id: agent.id,
              capabilities: agent.capabilities!,
            }))
          : data.agents;

        return textResult(formatAgents(visibleAgents));
      },
    })) as unknown as AnyAgentTool,
  );

  // ── viche_send ────────────────────────────────────────────────────────────
  // Captures `ctx.sessionKey` to:
  //   1. Record session activity for "most-recent" inbound routing.
  //   2. Store a correlation entry (messageId → sessionKey) so that incoming
  //      "result" replies can be routed back to this exact session.

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
        name: "viche_send",
        description:
          "Send a message to another AI agent on the Viche network. " +
          "Use this to delegate tasks, ask questions, or ping other agents. " +
          "You must know the target agent ID (use viche_discover first if needed).",
        parameters: Type.Object({
          to: Type.String({
            description:
              "Target agent ID (UUID format, e.g. '550e8400-e29b-41d4-a716-446655440000')",
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

          // Track session activity for "most-recent" inbound routing.
          state.mostRecentSessionKey = sessionKey;

          const msgType = params.type ?? "task";

          let data: SendMessageResponse | null = null;
          try {
            data = (await pushChannel(state.channel!, "send_message", {
              to: params.to,
              body: params.body,
              type: msgType,
            })) as SendMessageResponse;
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to send message: ${msg}`);
          }

          const messageId = getMessageId(data);
          if (!messageId) {
            return textResult(
              "Failed to send message: missing message_id in acknowledgement.",
            );
          }

          // Record correlation so "result" replies route back to this session.
          state.correlations.set(messageId, {
            sessionKey,
            timestamp: Date.now(),
          });

          return textResult(`Message sent to ${params.to} (type: ${msgType}).`);
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_reply ───────────────────────────────────────────────────────────
  // Captures `ctx.sessionKey` to update "most-recent" session activity.

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
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

          // Track session activity for "most-recent" inbound routing.
          state.mostRecentSessionKey = sessionKey;

          try {
            const response = await pushChannel(state.channel!, "send_message", {
              to: params.to,
              body: params.body,
              type: "result",
            });

            if (!getMessageId(response)) {
              return textResult(
                "Failed to send reply: missing message_id in acknowledgement.",
              );
            }
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to send reply: ${msg}`);
          }

          return textResult(`Reply sent to ${params.to}.`);
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_broadcast ───────────────────────────────────────────────────────
  // Captures `ctx.sessionKey` to update "most-recent" session activity.

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
        name: "viche_broadcast",
        description:
          "Broadcast a message to ALL agents in a given registry on the Viche network. " +
          "Every agent in the registry receives the message in their inbox.",
        parameters: Type.Object({
          registry: Type.String({
            description: "Registry token to broadcast to (e.g. 'global', 'team-alpha')",
          }),
          body: Type.String({
            description: "Message content to broadcast",
          }),
          type: Type.Optional(
            Type.Union([
              Type.Literal("task"),
              Type.Literal("result"),
              Type.Literal("ping"),
            ], {
              description: "Message type: 'task' (default), 'result', or 'ping'",
            }),
          ),
        }),
        async execute(
          _toolCallId: string,
          params: { registry: string; body: string; type?: string },
          _signal?: AbortSignal,
        ): Promise<AgentToolResult> {
          const guard = requireConnected(state);
          if (guard) return guard;

          state.mostRecentSessionKey = sessionKey;

          const msgType = params.type ?? "task";
          if (!validProtocolMessageType(msgType)) {
            return textResult(
              "Failed to broadcast: invalid message type (must be 'task', 'result', or 'ping')",
            );
          }

          try {
            const response = (await pushChannel(state.channel!, "broadcast_message", {
              registry: params.registry,
              body: params.body,
              type: msgType,
            })) as { recipients?: number };

            return textResult(
              `Broadcast sent to ${response.recipients ?? 0} agent(s) in registry '${params.registry}'.`,
            );
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to broadcast: ${msg}`);
          }
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_leave_registry ──────────────────────────────────────────────────
  // Captures `ctx.sessionKey` to update "most-recent" session activity.

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
        name: "viche_leave_registry",
        description:
          "Leave a registry on the Viche network. " +
          "If registry is specified, leaves only that registry. " +
          "If omitted, leaves ALL registries (becomes undiscoverable but stays connected).",
        parameters: Type.Object({
          registry: Type.Optional(
            Type.String({
              description:
                "Registry token to leave. If omitted, deregisters from all registries.",
              minLength: 4,
              maxLength: 256,
              pattern: "^[a-zA-Z0-9._-]+$",
            }),
          ),
        }),
        async execute(
          _toolCallId: string,
          params: { registry?: string },
          _signal?: AbortSignal,
        ): Promise<AgentToolResult> {
          const guard = requireConnected(state);
          if (guard) return guard;

          state.mostRecentSessionKey = sessionKey;

          const payload: Record<string, unknown> = {};
          if (params.registry) {
            payload.registry = params.registry;
          }

          try {
            const response = (await pushChannel(state.channel!, "deregister", payload)) as {
              registries: string[];
            };

            const registries = response.registries ?? [];
            if (registries.length === 0) {
              return textResult(
                "Left all registries. You are now undiscoverable but still connected.",
              );
            }

            return textResult(
              `Left registry '${params.registry}'. Remaining registries: ${registries.join(", ")}`,
            );
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to leave registry: ${msg}`);
          }
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_join_registry ───────────────────────────────────────────────────

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
        name: "viche_join_registry",
        description:
          "Join a registry on the Viche network. " +
          "Adds your agent to the specified registry for scoped discovery.",
        parameters: Type.Object({
          token: Type.String({
            description:
              "Registry token to join (4-256 chars, alphanumeric + . _ -).",
            minLength: 4,
            maxLength: 256,
            pattern: "^[a-zA-Z0-9._-]+$",
          }),
        }),
        async execute(
          _toolCallId: string,
          params: { token: string },
          _signal?: AbortSignal,
        ): Promise<AgentToolResult> {
          const guard = requireConnected(state);
          if (guard) return guard;

          state.mostRecentSessionKey = sessionKey;

          try {
            const response = (await pushChannel(state.channel!, "join_registry", {
              token: params.token,
            })) as { registries: string[] };

            const registries = response.registries ?? [];
            return textResult(
              `Joined registry '${params.token}'. Current registries: ${registries.join(", ")}`,
            );
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to join registry: ${msg}`);
          }
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_list_my_registries ──────────────────────────────────────────────

  api.registerTool(
    ((ctx: OpenClawPluginToolContext) => {
      const sessionKey = ctx.sessionKey ?? MAIN_SESSION;

      return {
        name: "viche_list_my_registries",
        description:
          "List the registries your agent is currently a member of on the Viche network.",
        parameters: Type.Object({}),
        async execute(
          _toolCallId: string,
          _params: Record<string, unknown>,
          _signal?: AbortSignal,
        ): Promise<AgentToolResult> {
          const guard = requireConnected(state);
          if (guard) return guard;

          state.mostRecentSessionKey = sessionKey;

          try {
            const response = (await pushChannel(state.channel!, "list_registries", {})) as {
              registries: string[];
            };

            if (!Array.isArray(response.registries)) {
              return textResult("Failed to list registries: invalid registries response");
            }

            return textResult(`Your registries: ${response.registries.join(", ")}`);
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            return textResult(`Failed to list registries: ${msg}`);
          }
        },
      };
    }) as unknown as AnyAgentTool,
  );

  // ── viche_whoami ──────────────────────────────────────────────────────────

  api.registerTool(
    ((_ctx: OpenClawPluginToolContext) => ({
      name: "viche_whoami",
      description:
        "Return your own agent ID on the Viche network. " +
        "Use this to identify yourself when coordinating with other agents.",
      parameters: Type.Object({}),
      async execute(
        _toolCallId: string,
        _params: Record<string, unknown>,
        _signal?: AbortSignal,
      ): Promise<AgentToolResult> {
        const guard = requireConnected(state);
        if (guard) return guard;

        return textResult(`Your agent ID: ${state.agentId}`);
      },
    })) as unknown as AnyAgentTool,
  );
}
