import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import {
  channelPush,
  DiscoverResponse,
  type AgentInfo,
  type PhoenixChannel,
} from "./service.js";

const NOT_CONNECTED_MESSAGE =
  "Not connected to Viche registry yet. Please wait for registration to complete.";

const TOOL_DEFINITIONS = [
  {
    name: "viche_discover",
    description:
      "Discover other AI agents on the Viche network by capability. Pass '*' to list all agents. Returns a list of agents that match.",
    inputSchema: {
      type: "object" as const,
      properties: {
        capability: {
          type: "string",
          description:
            "Capability to search for (e.g. 'coding', 'research', 'code-review'). Use '*' to return all agents.",
        },
        token: {
          type: "string",
          description:
            "Optional registry token to explicitly select which joined private registry channel to discover through.",
        },
      },
      required: ["capability"],
    },
  },
  {
    name: "viche_send",
    description:
      "Send a message to another AI agent on the Viche network. Use this to delegate tasks or ask questions to other agents.",
    inputSchema: {
      type: "object" as const,
      properties: {
        to: {
          type: "string",
          pattern:
            "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
          description: "Target agent ID (UUID format)",
        },
        body: {
          type: "string",
          description: "Message content",
        },
        type: {
          type: "string",
          description: "Message type: 'task', 'result', or 'ping'",
          default: "task",
        },
        in_reply_to: {
          type: "string",
          description: "Optional message ID this message is replying to (for threading)",
        },
        conversation_id: {
          type: "string",
          description: "Optional conversation ID to group related messages into a thread",
        },
      },
      required: ["to", "body"],
    },
  },
  {
    name: "viche_reply",
    description:
      "Reply to an agent that sent you a task. This sends a 'result' message back.",
    inputSchema: {
      type: "object" as const,
      properties: {
        to: {
          type: "string",
          description: "Agent ID to reply to (from the message's 'from' field)",
        },
        body: {
          type: "string",
          description: "Your result or response",
        },
        in_reply_to: {
          type: "string",
          description: "Optional message ID this reply is in response to (for threading)",
        },
        conversation_id: {
          type: "string",
          description: "Optional conversation ID to group related messages into a thread",
        },
      },
      required: ["to", "body"],
    },
  },
  {
    name: "viche_leave_registry",
    description:
      "Leave a registry on the Viche network. " +
      "If registry is specified, leaves only that registry. " +
      "If omitted, leaves ALL registries (becomes undiscoverable but stays connected).",
    inputSchema: {
      type: "object" as const,
      properties: {
        registry: {
          type: "string",
          description:
            "Optional registry token to leave. If omitted, leaves all registries.",
        },
      },
      required: [],
    },
  },
  {
    name: "viche_join_registry",
    description:
      "Join a registry on the Viche network. Adds your agent to the specified registry for scoped discovery.",
    inputSchema: {
      type: "object" as const,
      properties: {
        token: {
          type: "string",
          description: "Registry token to join (4-256 chars, alphanumeric + . _ -)",
          minLength: 4,
          maxLength: 256,
          pattern: "^[a-zA-Z0-9._-]+$",
        },
      },
      required: ["token"],
    },
  },
  {
    name: "viche_list_my_registries",
    description:
      "List the registries your agent is currently a member of on the Viche network.",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "viche_whoami",
    description:
      "Return your own agent ID on the Viche network. Use this to identify yourself when coordinating with other agents.",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
];

export function formatAgentList(agents: AgentInfo[]): string {
  if (agents.length === 0) {
    return "No agents found matching that capability.";
  }
  const lines = agents.map((a) => {
    const caps = a.capabilities?.join(", ") ?? "unknown";
    const name = a.name ? ` (${a.name})` : "";
    return `• ${a.id}${name} — capabilities: ${caps}`;
  });
  return `Found ${agents.length} agent(s):\n${lines.join("\n")}`;
}

function notConnectedResponse() {
  return {
    content: [{ type: "text" as const, text: NOT_CONNECTED_MESSAGE }],
  };
}

function formatToolError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);

  try {
    const parsed = JSON.parse(raw) as { message?: unknown; error?: unknown };
    if (typeof parsed.message === "string" && parsed.message.length > 0) {
      return parsed.message;
    }
    if (typeof parsed.error === "string" && parsed.error.length > 0) {
      return parsed.error;
    }
  } catch {
    // Non-JSON string, keep raw message.
  }

  return raw;
}

export function registerToolHandlers(
  server: Server,
  getChannel: () => PhoenixChannel | null,
  getAgentId: () => string | null,
  getRegistryChannels: () => Map<string, PhoenixChannel>
): void {
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOL_DEFINITIONS,
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const toolName = request.params.name;

    if (toolName === "viche_discover") {
      const args = request.params.arguments as { capability: string; token?: string };
      try {
        const token = args.token?.trim();
        let discoverChannel: PhoenixChannel | null = null;

        if (token) {
          discoverChannel = getRegistryChannels().get(token) ?? null;
        } else if (getRegistryChannels().size > 0) {
          discoverChannel = getRegistryChannels().values().next().value ?? null;
        } else {
          discoverChannel = getChannel();
        }

        if (token && !discoverChannel) {
          return {
            content: [
              {
                type: "text",
                text: `Discovery failed: not joined to requested registry token '${token}'.`,
              },
            ],
          };
        }

        if (!discoverChannel) {
          return notConnectedResponse();
        }

        const discoverPayload: { capability: string; registry?: string } = {
          capability: args.capability,
        };

        if (token) {
          discoverPayload.registry = token;
        }

        const resp = await channelPush<DiscoverResponse>(
          discoverChannel,
          "discover",
          discoverPayload
        );

        return {
          content: [{ type: "text", text: formatAgentList(resp.agents ?? []) }],
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Discovery failed: ${message}` }],
        };
      }
    }

    if (toolName === "viche_send") {
      const args = request.params.arguments as {
        to: string;
        body: string;
        type?: string;
        in_reply_to?: string;
        conversation_id?: string;
      };
      const msgType = args.type ?? "task";
      try {
        const channel = getChannel();
        if (!channel) {
          return notConnectedResponse();
        }

        const payload: Record<string, unknown> = {
          to: args.to,
          body: args.body,
          type: msgType,
        };
        if (args.in_reply_to) payload.in_reply_to = args.in_reply_to;
        if (args.conversation_id) payload.conversation_id = args.conversation_id;

        await channelPush(channel, "send_message", payload);
        return {
          content: [
            {
              type: "text",
              text: `Message sent to ${args.to} (type: ${msgType}).`,
            },
          ],
        };
      } catch (err) {
        const message = formatToolError(err);
        return {
          content: [{ type: "text", text: `Failed to send message: ${message}` }],
        };
      }
    }

    if (toolName === "viche_reply") {
      const args = request.params.arguments as {
        to: string;
        body: string;
        in_reply_to?: string;
        conversation_id?: string;
      };
      try {
        const channel = getChannel();
        if (!channel) {
          return notConnectedResponse();
        }

        const payload: Record<string, unknown> = {
          to: args.to,
          body: args.body,
          type: "result",
        };
        if (args.in_reply_to) payload.in_reply_to = args.in_reply_to;
        if (args.conversation_id) payload.conversation_id = args.conversation_id;

        await channelPush(channel, "send_message", payload);
        return {
          content: [{ type: "text", text: `Reply sent to ${args.to}.` }],
        };
      } catch (err) {
        const message = formatToolError(err);
        return {
          content: [{ type: "text", text: `Failed to send reply: ${message}` }],
        };
      }
    }

    if (toolName === "viche_leave_registry") {
      const args = request.params.arguments as { registry?: string };
      try {
        const channel = getChannel();
        if (!channel) {
          return notConnectedResponse();
        }

        const payload: Record<string, unknown> = {};
        if (args.registry) {
          payload.registry = args.registry;
        }

        const resp = await channelPush<{ registries: string[] }>(
          channel,
          "deregister",
          payload
        );

        const registries = resp.registries ?? [];
        if (registries.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: "Left all registries. You are now undiscoverable but still connected.",
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: `Left registry '${args.registry}'. Remaining registries: ${registries.join(", ")}`,
            },
          ],
        };
      } catch (err) {
        const message = formatToolError(err);
        return {
          content: [{ type: "text", text: `Failed to leave registry: ${message}` }],
        };
      }
    }

    if (toolName === "viche_join_registry") {
      const args = request.params.arguments as { token: string };
      try {
        const channel = getChannel();
        if (!channel) {
          return notConnectedResponse();
        }

        const resp = await channelPush<{ registries: string[] }>(
          channel,
          "join_registry",
          { token: args.token }
        );

        if (!Array.isArray(resp.registries)) {
          return {
            content: [
              {
                type: "text",
                text: "Failed to join registry: invalid registries response",
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: `Joined registry '${args.token}'. Current registries: ${resp.registries.join(", ")}`,
            },
          ],
        };
      } catch (err) {
        const message = formatToolError(err);
        return {
          content: [{ type: "text", text: `Failed to join registry: ${message}` }],
        };
      }
    }

    if (toolName === "viche_list_my_registries") {
      try {
        const channel = getChannel();
        if (!channel) {
          return notConnectedResponse();
        }

        const resp = await channelPush<{ registries: string[] }>(
          channel,
          "list_registries",
          {}
        );

        return {
          content: [
            {
              type: "text",
              text: `Your registries: ${(resp.registries ?? []).join(", ")}`,
            },
          ],
        };
      } catch (err) {
        const message = formatToolError(err);
        return {
          content: [{ type: "text", text: `Failed to list registries: ${message}` }],
        };
      }
    }

    if (toolName === "viche_whoami") {
      const agentId = getAgentId();
      if (!agentId) {
        return notConnectedResponse();
      }
      return {
        content: [{ type: "text" as const, text: `Your agent ID: ${agentId}` }],
      };
    }

    throw new Error(`Unknown tool: ${toolName}`);
  });
}
