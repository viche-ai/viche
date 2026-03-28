import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

// ── Configuration ──────────────────────────────────────────────────────────────

const REGISTRY_URL =
  process.env.VICHE_REGISTRY_URL ?? "http://localhost:4000";
const AGENT_NAME = process.env.VICHE_AGENT_NAME ?? null;
const CAPABILITIES = (process.env.VICHE_CAPABILITIES ?? "coding")
  .split(",")
  .map((c) => c.trim())
  .filter(Boolean);
const DESCRIPTION = process.env.VICHE_DESCRIPTION ?? null;
const POLL_INTERVAL_S = parseInt(process.env.VICHE_POLL_INTERVAL ?? "5", 10);

// ── Types ──────────────────────────────────────────────────────────────────────

interface RegisterBody {
  capabilities: string[];
  name?: string;
  description?: string;
}

interface RegisterResponse {
  id: string;
}

interface Message {
  id: string;
  from: string;
  body: string;
  type: string;
}

interface InboxResponse {
  messages: Message[];
}

// ── Registration ───────────────────────────────────────────────────────────────

async function register(): Promise<string> {
  const body: RegisterBody = { capabilities: CAPABILITIES };
  if (AGENT_NAME) body.name = AGENT_NAME;
  if (DESCRIPTION) body.description = DESCRIPTION;

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
        process.stderr.write(
          `Viche: registration failed after ${MAX_ATTEMPTS} attempts: ${message}\n`
        );
        process.exit(1);
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

// ── Polling ────────────────────────────────────────────────────────────────────

async function pollInbox(
  agentId: string,
  server: Server
): Promise<void> {
  try {
    const response = await fetch(`${REGISTRY_URL}/inbox/${agentId}`);
    if (!response.ok) {
      process.stderr.write(
        `Viche: poll warning — ${response.status} ${response.statusText}\n`
      );
      return;
    }

    const data = (await response.json()) as InboxResponse;
    const messages = data.messages ?? [];

    for (const msg of messages) {
      await server.notification({
        method: "notifications/claude/channel",
        params: {
          channel: "viche",
          content: `[Task from ${msg.from}] ${msg.body}`,
          meta: {
            message_id: msg.id,
            from: msg.from,
          },
        },
      });
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Viche: poll warning — ${message}\n`);
  }
}

function startPollLoop(agentId: string, server: Server): void {
  const intervalMs = POLL_INTERVAL_S * 1000;
  const tick = () => {
    pollInbox(agentId, server).finally(() => {
      setTimeout(tick, intervalMs);
    });
  };
  setTimeout(tick, intervalMs);
}

// ── Utilities ──────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const server = new Server(
    {
      name: "viche-channel",
      version: "0.1.0",
    },
    {
      capabilities: {
        experimental: { "claude/channel": {} },
        tools: {},
      },
      instructions:
        "Viche channel: tasks from other AI agents. Execute the task, then call viche_reply with your result.",
    }
  );

  // Register agent with retry
  const agentId = await registerWithRetry();

  // List tools handler
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "viche_reply",
        description:
          "Send a reply to an agent that sent you a task via Viche. Call this after completing the task.",
        inputSchema: {
          type: "object" as const,
          properties: {
            to: {
              type: "string",
              description:
                "Agent ID to send the reply to (from the original message's 'from' field)",
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
    if (request.params.name !== "viche_reply") {
      throw new Error(`Unknown tool: ${request.params.name}`);
    }

    const args = request.params.arguments as { to: string; body: string };
    const { to, body } = args;

    try {
      const response = await fetch(`${REGISTRY_URL}/messages/${to}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type: "result",
          from: agentId,
          body,
        }),
      });

      if (!response.ok) {
        const text = await response.text();
        return {
          content: [
            {
              type: "text",
              text: `Failed to send reply: ${response.status} ${response.statusText} — ${text}`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text",
            text: `Reply sent to ${to}.`,
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [
          {
            type: "text",
            text: `Failed to send reply: ${message}`,
          },
        ],
      };
    }
  });

  // Start transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Start polling after connection
  startPollLoop(agentId, server);

  process.stderr.write(
    `Viche: registered as ${agentId}, polling every ${POLL_INTERVAL_S}s\n`
  );
}

main().catch((err) => {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Viche: fatal error — ${message}\n`);
  process.exit(1);
});
