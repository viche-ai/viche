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
  .map((c: string) => c.trim())
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
  .map((t: string) => t.trim())
  .filter(Boolean);

// ── Types ──────────────────────────────────────────────────────────────────────

interface RegisterJoinPayload {
  capabilities: string[];
  name?: string;
  description?: string;
  registries?: string[];
}

interface RegisterJoinResponse {
  agent_id: string;
}

interface AgentInfo {
  id: string;
  name?: string;
  capabilities?: string[];
}

interface DiscoverResponse {
  agents: AgentInfo[];
}

// ── WebSocket / Phoenix Channel ────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixChannel = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PhoenixSocket = any;

let activeChannel: PhoenixChannel | null = null;
let activeSocket: PhoenixSocket | null = null;
let activeAgentId: string | null = null;
const registryChannels = new Map<string, PhoenixChannel>();
let recovering = false;
const NOT_CONNECTED_MESSAGE =
  "Not connected to Viche registry yet. Please wait for registration to complete.";

function clearRegistryChannels(): void {
  for (const channel of registryChannels.values()) {
    try {
      channel.leave?.();
    } catch {
      // Best-effort teardown: leave/disconnect failures are non-fatal because reconnect builds fresh socket/channel state.
    }
  }
  registryChannels.clear();
}

function clearActiveConnection(): void {
  if (activeChannel) {
    try {
      activeChannel.leave?.();
    } catch {
      // Ignore cleanup failures.
    }
    activeChannel = null;
  }

  clearRegistryChannels();

  if (activeSocket) {
    try {
      activeSocket.disconnect?.();
    } catch {
      // Ignore cleanup failures.
    }
    activeSocket = null;
  }

  activeAgentId = null;
}

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

function connectAndRegister(server: Server): Promise<void> {
  const registerPayload: RegisterJoinPayload = { capabilities: CAPABILITIES };
  if (AGENT_NAME) registerPayload.name = AGENT_NAME;
  if (DESCRIPTION) registerPayload.description = DESCRIPTION;
  if (REGISTRY_TOKENS.length) registerPayload.registries = REGISTRY_TOKENS;

  const wsBase = REGISTRY_URL.replace(/^http/, "ws");
  const wsUrl = `${wsBase}/agent/websocket`;

  return new Promise<void>((resolve, reject) => {
    let settled = false;
    let channel: PhoenixChannel | undefined;

    const socket: PhoenixSocket = new Socket(wsUrl, {
      reconnectAfterMs: (tries: number) =>
        ([1000, 2000, 5000, 10000] as const)[tries - 1] ?? 10000,
    });

    socket.onError((err: unknown) => {
      if (!settled) {
        try {
          channel?.leave?.();
        } catch {
          // Ignore cleanup failures.
        }
        try {
          socket.disconnect?.();
        } catch {
          // Ignore cleanup failures.
        }

        settled = true;
        reject(
          new Error(
            `WebSocket connection error: ${
              err instanceof Error ? err.message : JSON.stringify(err)
            }`
          )
        );
      }
    });

    socket.onClose(() => {
      process.stderr.write(
        "Viche: WebSocket disconnected — will reconnect automatically\n"
      );
    });

    socket.onOpen(() => {
      process.stderr.write("Viche: WebSocket (re)connected\n");
    });

    const registerChannel: PhoenixChannel = socket.channel(
      "agent:register",
      registerPayload
    );
    channel = registerChannel;

    socket.connect();

    registerChannel.onError?.((reason: unknown) => {
      if (!settled || recovering || activeChannel !== registerChannel) {
        return;
      }

      recovering = true;

      const reasonString =
        typeof reason === "string" ? reason : JSON.stringify(reason);
      process.stderr.write(
        `Viche: channel error (${reasonString}) — reconnecting and re-registering\n`
      );

      const staleChannel = activeChannel;
      const staleSocket = activeSocket;

      activeChannel = null;
      activeSocket = null;
      activeAgentId = null;
      clearRegistryChannels();

      try {
        staleChannel?.leave?.();
      } catch {
        // Ignore stale channel cleanup failures.
      }

      try {
        staleSocket?.disconnect?.();
      } catch {
        // Ignore stale socket cleanup failures.
      }

      void connectAndRegisterWithRetry(server)
        .then(() => {
          process.stderr.write(
            `Viche: recovered — re-registered as ${activeAgentId}\n`
          );
        })
        .catch((err: unknown) => {
          const message = err instanceof Error ? err.message : String(err);
          process.stderr.write(`Viche: channel recovery failed: ${message}\n`);
        })
        .finally(() => {
          recovering = false;
        });
    });

    registerChannel.on(
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

    registerChannel
      .join()
      .receive("ok", (resp: RegisterJoinResponse) => {
        clearRegistryChannels();

        activeSocket = socket;
        activeChannel = registerChannel;
        activeAgentId = resp.agent_id;
        process.stderr.write(
          `Viche: registered as ${activeAgentId}, connected via WebSocket\n`
        );

        for (const token of REGISTRY_TOKENS) {
          const registryChannel = socket.channel(`registry:${token}`, {});
          registryChannel
            .join()
            .receive("ok", () => {
              registryChannels.set(token, registryChannel);
            })
            .receive("error", (registryResp: unknown) => {
              process.stderr.write(
                `Viche: registry channel join failed for ${token}: ${JSON.stringify(registryResp)}\n`
              );
            });
        }

        if (!settled) {
          settled = true;
          resolve();
        }
      })
      .receive("error", (resp: unknown) => {
        try {
          registerChannel.leave?.();
        } catch {
          // Ignore cleanup failures.
        }
        try {
          socket.disconnect?.();
        } catch {
          // Ignore cleanup failures.
        }

        if (!settled) {
          settled = true;
          reject(new Error(`Channel join failed: ${JSON.stringify(resp)}`));
        }
      })
      .receive("timeout", () => {
        try {
          registerChannel.leave?.();
        } catch {
          // Ignore cleanup failures.
        }
        try {
          socket.disconnect?.();
        } catch {
          // Ignore cleanup failures.
        }

        if (!settled) {
          settled = true;
          reject(new Error("Channel join timed out"));
        }
      });
  });
}

async function connectAndRegisterWithRetry(server: Server): Promise<void> {
  const MAX_ATTEMPTS = 3;
  const BACKOFF_MS = 2000;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      await connectAndRegister(server);
      return;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (attempt === MAX_ATTEMPTS) {
        throw new Error(
          `Viche: websocket registration failed after ${MAX_ATTEMPTS} attempts: ${message}`
        );
      }
      process.stderr.write(
        `Viche: websocket registration attempt ${attempt} failed: ${message}. Retrying in ${BACKOFF_MS / 1000}s...\n`
      );
      await sleep(BACKOFF_MS);
    }
  }

  throw new Error("Unreachable");
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

function notConnectedResponse() {
  return {
    content: [{ type: "text" as const, text: NOT_CONNECTED_MESSAGE }],
  };
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
      {
        name: "viche_deregister",
        description:
          "Deregister from a registry on the Viche network. " +
          "If registry is specified, leaves only that registry. " +
          "If omitted, leaves ALL registries (becomes undiscoverable but stays connected).",
        inputSchema: {
          type: "object" as const,
          properties: {
            registry: {
              type: "string",
              description:
                "Optional registry token to leave. If omitted, deregisters from all registries.",
            },
          },
          required: [],
        },
      },
    ],
  }));

  // Call tool handler
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const toolName = request.params.name;

    if (toolName === "viche_discover") {
      const args = request.params.arguments as { capability: string; token?: string };
      try {
        const token = args.token?.trim();
        let discoverChannel: PhoenixChannel | null = null;

        if (token) {
          discoverChannel = registryChannels.get(token) ?? null;
        } else if (registryChannels.size > 0) {
          discoverChannel = registryChannels.values().next().value ?? null;
        } else {
          discoverChannel = activeChannel;
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
      };
      const msgType = args.type ?? "task";
      try {
        if (!activeChannel) {
          return notConnectedResponse();
        }

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
        if (!activeChannel) {
          return notConnectedResponse();
        }

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

    if (toolName === "viche_deregister") {
      const args = request.params.arguments as { registry?: string };
      try {
        if (!activeChannel) {
          return notConnectedResponse();
        }

        const payload: Record<string, unknown> = {};
        if (args.registry) {
          payload.registry = args.registry;
        }

        const resp = await channelPush<{ registries: string[] }>(
          activeChannel,
          "deregister",
          payload
        );

        const registries = resp.registries ?? [];
        if (registries.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: "Deregistered from all registries. You are now undiscoverable but still connected.",
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: `Deregistered from registry '${args.registry}'. Remaining registries: ${registries.join(", ")}`,
            },
          ],
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Failed to deregister: ${message}` }],
        };
      }
    }

    throw new Error(`Unknown tool: ${toolName}`);
  });

  // Start transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Connect to Phoenix Channel and register via channel join
  await connectAndRegisterWithRetry(server);

  const shutdown = () => {
    clearActiveConnection();
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Viche: fatal error — ${message}\n`);
  process.exit(1);
});
