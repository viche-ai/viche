import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
// @ts-ignore — phoenix ships CJS without ESM types; runtime import works fine in Bun
import { Socket } from "phoenix";

// ── Configuration ──────────────────────────────────────────────────────────────

const REGISTRY_URL =
  process.env.VICHE_REGISTRY_URL ||
  process.env.CLAUDE_PLUGIN_OPTION_REGISTRY_URL ||
  "http://localhost:4000";
const AGENT_NAME =
  process.env.VICHE_AGENT_NAME ||
  process.env.CLAUDE_PLUGIN_OPTION_AGENT_NAME ||
  "claude-code";
const CAPABILITIES = (
  process.env.VICHE_CAPABILITIES ||
  process.env.CLAUDE_PLUGIN_OPTION_CAPABILITIES ||
  "coding"
)
  .split(",")
  .map((c) => c.trim())
  .filter(Boolean);
const DESCRIPTION =
  process.env.VICHE_DESCRIPTION ||
  process.env.CLAUDE_PLUGIN_OPTION_DESCRIPTION ||
  "Claude Code AI assistant connected via Viche";
const REGISTRY_TOKENS: string[] = (
  process.env.VICHE_REGISTRY_TOKEN ||
  process.env.CLAUDE_PLUGIN_OPTION_REGISTRIES ||
  ""
)
  .split(",")
  .map((t) => t.trim())
  .filter(Boolean);

// ── Types ──────────────────────────────────────────────────────────────────────

interface RegisterBody {
  capabilities: string[];
  name?: string;
  description?: string;
  registries?: string[];
}

interface RegisterResponse {
  id: string;
}

interface AgentInfo {
  id: string;
  name?: string;
  capabilities?: string[];
}

interface DiscoverResponse {
  agents: AgentInfo[];
}

// ── Registration ───────────────────────────────────────────────────────────────

async function register(): Promise<string> {
  const body: RegisterBody = { capabilities: CAPABILITIES };
  if (AGENT_NAME) body.name = AGENT_NAME;
  if (DESCRIPTION) body.description = DESCRIPTION;
  if (REGISTRY_TOKENS.length) body.registries = REGISTRY_TOKENS;

  const response = await fetch(`${REGISTRY_URL}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    throw new Error(
      `Registration failed: ${response.status} ${response.statusText}`
    );
  }

  const data = (await response.json()) as RegisterResponse;
  return data.id;
}

async function registerWithRetry(): Promise<string> {
  const MAX_ATTEMPTS = 3;
  const BACKOFF_MS = 2000;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      return await register();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (attempt === MAX_ATTEMPTS) {
        throw new Error(
          `Viche: registration failed after ${MAX_ATTEMPTS} attempts: ${message}`
        );
      }
      process.stderr.write(
        `Viche: registration attempt ${attempt} failed: ${message}. Retrying in ${BACKOFF_MS / 1000}s...\n`
      );
      await sleep(BACKOFF_MS);
    }
  }

  // Unreachable, but TypeScript needs it
  throw new Error("Unreachable");
}

// ── WebSocket / Phoenix Channel ────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixChannel = any;

let activeChannel: PhoenixChannel | null = null;
const registryChannels = new Map<string, PhoenixChannel>();

function channelPush<T>(
  channel: PhoenixChannel,
  event: string,
  payload: Record<string, unknown>
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    channel
      .push(event, payload)
      .receive("ok", (resp: T) => resolve(resp))
      .receive("error", (resp: unknown) => {
        reject(new Error(JSON.stringify(resp)));
      })
      .receive("timeout", () => {
        reject(new Error("Channel push timed out"));
      });
  });
}

function connectWebSocket(agentId: string, server: Server): void {
  const wsBase = REGISTRY_URL.replace(/^http/, "ws");
  const wsUrl = `${wsBase}/agent/websocket`;

  const socket = new Socket(wsUrl, { params: { agent_id: agentId } });
  socket.connect();

  const channel: PhoenixChannel = socket.channel(`agent:${agentId}`, {});

  channel.on(
    "new_message",
    (payload: { id: string; type?: string; from: string; body: string }) => {
      const messageType = payload.type ?? "task";
      const displayType =
        messageType.charAt(0).toUpperCase() + messageType.slice(1);

      server
        .notification({
          method: "notifications/claude/channel",
          params: {
            content: `[${displayType} from ${payload.from}] ${payload.body}`,
            meta: {
              message_id: payload.id,
              from: payload.from,
              type: messageType,
            },
          },
        })
        .catch((err: unknown) => {
          const msg = err instanceof Error ? err.message : String(err);
          process.stderr.write(`Viche: notification error — ${msg}\n`);
        });
    }
  );

  channel
    .join()
    .receive("ok", () => {
      activeChannel = channel;
      process.stderr.write(
        `Viche: registered as ${agentId}, connected via WebSocket\n`
      );

      for (const token of REGISTRY_TOKENS) {
        const registryChannel = socket.channel(`registry:${token}`, {});
        registryChannel
          .join()
          .receive("ok", () => {
            registryChannels.set(token, registryChannel);
          })
          .receive("error", (resp: unknown) => {
            process.stderr.write(
              `Viche: registry channel join failed for ${token}: ${JSON.stringify(resp)}\n`
            );
          });
      }
    })
    .receive("error", (resp: unknown) => {
      process.stderr.write(
        `Viche: channel join failed — ${JSON.stringify(resp)}\n`
      );
    });
}

// ── Utilities ──────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatAgentList(agents: AgentInfo[]): string {
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

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const server = new Server(
    {
      name: "viche-channel",
      version: "1.0.0",
    },
    {
      capabilities: {
        experimental: { "claude/channel": {} },
        tools: {},
      },
      instructions:
        'Viche channel: tasks from other AI agents arrive as <channel source="viche"> tags. Execute the task immediately, then call viche_reply with your result.',
    }
  );

  // Register agent with retry (HTTP, needed before WebSocket join)
  const agentId = await registerWithRetry();

  // List tools handler
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
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
              pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
              description: "Target agent ID (UUID format)",
            },
            body: {
              type: "string",
              description: "Message content",
            },
            type: {
              type: "string",
              description:
                "Message type: 'task', 'result', or 'ping'",
              default: "task",
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
              description:
                "Agent ID to reply to (from the message's 'from' field)",
            },
            body: {
              type: "string",
              description: "Your result or response",
            },
          },
          required: ["to", "body"],
        },
      },
    ],
  }));

  // Call tool handler
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const toolName = request.params.name;

    if (!activeChannel) {
      return {
        content: [
          {
            type: "text",
            text: "Viche channel is not yet connected. Please wait a moment and try again.",
          },
        ],
      };
    }

    if (toolName === "viche_discover") {
      const args = request.params.arguments as { capability: string; token?: string };
      try {
        const token = args.token;
        let discoverChannel: PhoenixChannel;

        if (token && registryChannels.has(token)) {
          discoverChannel = registryChannels.get(token)!;
        } else if (registryChannels.size > 0) {
          discoverChannel = registryChannels.values().next().value!;
        } else {
          discoverChannel = activeChannel;
        }

        const resp = await channelPush<DiscoverResponse>(discoverChannel, "discover", {
          capability: args.capability,
        });

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
      };
      const msgType = args.type ?? "task";
      try {
        await channelPush(activeChannel, "send_message", {
          to: args.to,
          body: args.body,
          type: msgType,
        });
        return {
          content: [
            {
              type: "text",
              text: `Message sent to ${args.to} (type: ${msgType}).`,
            },
          ],
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Failed to send message: ${message}` }],
        };
      }
    }

    if (toolName === "viche_reply") {
      const args = request.params.arguments as { to: string; body: string };
      try {
        await channelPush(activeChannel, "send_message", {
          to: args.to,
          body: args.body,
          type: "result",
        });
        return {
          content: [{ type: "text", text: `Reply sent to ${args.to}.` }],
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Failed to send reply: ${message}` }],
        };
      }
    }

    throw new Error(`Unknown tool: ${toolName}`);
  });

  // Start transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Connect to Phoenix Channel (non-blocking; notifications arrive via WebSocket)
  connectWebSocket(agentId, server);
}

main().catch((err) => {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Viche: fatal error — ${message}\n`);
  process.exit(1);
});
