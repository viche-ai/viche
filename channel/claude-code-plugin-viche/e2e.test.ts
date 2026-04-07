import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { z } from "zod";

const BASE_URL = "http://localhost:4000";
const UUID_V4_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type ToolTextResult = {
  content: Array<{ type: string; text: string }>;
};

type InboxMessage = {
  id: string;
  from: string;
  body: string;
  type: string;
};

type Agent = { id: string; capabilities?: string[] };

type VicheServerInstance = {
  server: {
    connect: (transport: InMemoryTransport) => Promise<void>;
    close: () => Promise<void>;
  };
  getAgentId: () => string | null;
  waitForReady: () => Promise<void>;
  cleanup: () => void;
};

type Session = {
  client: Client;
  vicheServer: VicheServerInstance;
};

type ServiceModule = {
  connectAndRegisterWithRetry: (server: VicheServerInstance["server"]) => Promise<void>;
  clearActiveConnection: () => void;
  getActiveAgentId: () => string | null;
  getActiveChannel: () => unknown;
  getRegistryChannels: () => Map<string, unknown>;
};

type ToolModule = {
  registerToolHandlers: (
    server: unknown,
    getChannel: () => unknown,
    getAgentId: () => string | null,
    getRegistryChannels: () => Map<string, unknown>
  ) => void;
};

type ServerCtorModule = {
  Server: new (
    serverInfo: { name: string; version: string },
    options: {
      capabilities: {
        experimental: { "claude/channel": Record<string, never> };
        tools: Record<string, never>;
      };
      instructions: string;
    }
  ) => VicheServerInstance["server"];
};

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function withTempEnv(
  values: Record<string, string | undefined>,
  fn: () => Promise<void>
): Promise<void> {
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(values)) {
    previous.set(key, process.env[key]);
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }

  return fn().finally(() => {
    for (const [key, value] of previous.entries()) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  });
}

async function registerAgent(capabilities: string[], name?: string): Promise<string> {
  const body: Record<string, unknown> = { capabilities };
  if (name) body.name = name;

  const resp = await fetch(`${BASE_URL}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    throw new Error(`Registration failed: ${resp.status}`);
  }

  const { id } = (await resp.json()) as { id: string };
  return id;
}

async function drainInbox(agentId: string): Promise<InboxMessage[]> {
  const resp = await fetch(`${BASE_URL}/inbox/${agentId}`);
  if (!resp.ok) {
    throw new Error(`Inbox read failed: ${resp.status}`);
  }
  const { messages } = (await resp.json()) as { messages: InboxMessage[] };
  return messages;
}

async function discover(capability: string, registry?: string): Promise<Agent[]> {
  const params = new URLSearchParams({ capability });
  if (registry) params.set("registry", registry);
  const resp = await fetch(`${BASE_URL}/registry/discover?${params.toString()}`);
  if (!resp.ok) {
    throw new Error(`Discovery failed: ${resp.status}`);
  }
  const { agents } = (await resp.json()) as { agents: Agent[] };
  return agents;
}

async function waitForAgentAbsence(
  targetAgentId: string,
  timeoutMs: number,
  registry?: string
): Promise<boolean> {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    const agents = await discover("*", registry);
    if (!agents.some((agent) => agent.id === targetAgentId)) {
      return true;
    }
    await wait(500);
  }

  return false;
}

async function createSession(): Promise<Session> {
  const [{ createVicheServer }, serviceModule] = await Promise.all([
    import("./server.ts"),
    import("./service.ts"),
  ]);

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

  const vicheServer = createVicheServer() as VicheServerInstance;
  await vicheServer.server.connect(serverTransport);
  await (serviceModule as ServiceModule).connectAndRegisterWithRetry(vicheServer.server);

  const client = new Client(
    { name: "test-client", version: "1.0.0" },
    { capabilities: {} }
  );
  await client.connect(clientTransport);

  await vicheServer.waitForReady();

  return { client, vicheServer };
}

async function createIsolatedSession(query: string): Promise<Session> {
  const [serverCtorModule, toolModule, serviceModule] = await Promise.all([
    import("@modelcontextprotocol/sdk/server/index.js"),
    import(`./tools.ts${query}`),
    import(`./service.ts${query}`),
  ]);

  const { Server } = serverCtorModule as ServerCtorModule;
  const { registerToolHandlers } = toolModule as ToolModule;
  const service = serviceModule as ServiceModule;

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

  registerToolHandlers(
    server,
    service.getActiveChannel,
    service.getActiveAgentId,
    service.getRegistryChannels
  );

  const waitForReady = async (): Promise<void> => {
    const start = Date.now();
    while (service.getActiveAgentId() === null) {
      if (Date.now() - start > 60_000) {
        throw new Error("Timed out waiting for Viche registration");
      }
      await wait(50);
    }
  };

  const vicheServer: VicheServerInstance = {
    server,
    getAgentId: service.getActiveAgentId,
    waitForReady,
    cleanup: service.clearActiveConnection,
  };

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await vicheServer.server.connect(serverTransport);
  await service.connectAndRegisterWithRetry(vicheServer.server);

  const client = new Client(
    { name: "test-client", version: "1.0.0" },
    { capabilities: {} }
  );
  await client.connect(clientTransport);
  await vicheServer.waitForReady();

  return { client, vicheServer };
}

function getToolText(result: unknown): string {
  const typed = result as ToolTextResult;
  return typed.content[0]?.text ?? "";
}

async function closeSession(session: Session): Promise<void> {
  session.vicheServer.cleanup();
  await session.client.close();
  await session.vicheServer.server.close();
}

describe("E2E: claude-code-plugin-viche with InMemoryTransport", () => {
  const runId = Date.now();
  let session: Session;
  let agentId: string;

  beforeAll(async () => {
    process.env.VICHE_REGISTRY_URL = BASE_URL;
    process.env.VICHE_AGENT_NAME = `claude-e2e-main-${runId}`;
    process.env.VICHE_CAPABILITIES = "coding,e2e-testing";

    session = await createSession();

    const resolvedAgentId = session.vicheServer.getAgentId();
    if (!resolvedAgentId) {
      throw new Error("Expected server to expose a registered agent ID");
    }
    agentId = resolvedAgentId;
  }, 90_000);

  afterAll(async () => {
    if (session) {
      await closeSession(session);
    }
  });

  it("1) listTools returns all four tools", async () => {
    const response = await session.client.listTools();
    const toolNames = response.tools.map((tool) => tool.name).sort();

    expect(response.tools).toHaveLength(4);
    expect(toolNames).toEqual([
      "viche_deregister",
      "viche_discover",
      "viche_reply",
      "viche_send",
    ]);
  });

  it("2) registration + discovery exposes our UUID agent", async () => {
    expect(agentId).toMatch(UUID_V4_REGEX);

    const result = await session.client.callTool({
      name: "viche_discover",
      arguments: { capability: "*" },
    });

    const text = getToolText(result);
    expect(text).toContain(agentId);
  });

  it("3) viche_send delivers to external inbox", async () => {
    const externalId = await registerAgent(["e2e-target"], `target-${Date.now()}`);

    const result = await session.client.callTool({
      name: "viche_send",
      arguments: {
        to: externalId,
        body: "hello from claude e2e",
        type: "task",
      },
    });

    expect(getToolText(result)).toContain("Message sent");

    const inbox = await drainInbox(externalId);
    expect(inbox).toHaveLength(1);
    expect(inbox[0]?.from).toBe(agentId);
    expect(inbox[0]?.body).toBe("hello from claude e2e");
    expect(inbox[0]?.type).toBe("task");
  });

  it("4) viche_reply sends type=result", async () => {
    const externalId = await registerAgent(["e2e-reply-target"], `reply-target-${Date.now()}`);

    const result = await session.client.callTool({
      name: "viche_reply",
      arguments: {
        to: externalId,
        body: "reply payload",
      },
    });

    expect(getToolText(result)).toContain("Reply sent");

    const inbox = await drainInbox(externalId);
    expect(inbox).toHaveLength(1);
    expect(inbox[0]?.type).toBe("result");
    expect(inbox[0]?.body).toBe("reply payload");
  });

  it("5) viche_deregister(registry) leaves only that registry", async () => {
    const registry = `e2e-claude-partial-${Date.now()}`;

    await withTempEnv(
      {
        VICHE_REGISTRY_URL: BASE_URL,
        VICHE_REGISTRY_TOKEN: `global,${registry}`,
        VICHE_AGENT_NAME: `claude-e2e-partial-${Date.now()}`,
      },
      async () => {
        const isolated = await createIsolatedSession(`?partial=${Date.now()}`);

        try {
          const isolatedAgentId = isolated.vicheServer.getAgentId();
          expect(isolatedAgentId).toBeTruthy();

          const result = await isolated.client.callTool({
            name: "viche_deregister",
            arguments: { registry },
          });
          expect(getToolText(result)).toContain(`Deregistered from registry '${registry}'`);

          const globalAgents = await discover("*", "global");
          const privateAgents = await discover("*", registry);

          expect(globalAgents.some((a) => a.id === isolatedAgentId)).toBeTrue();
          expect(privateAgents.some((a) => a.id === isolatedAgentId)).toBeFalse();
        } finally {
          await closeSession(isolated);
        }
      }
    );
  }, 90_000);

  it("6) viche_deregister() removes agent from all registries", async () => {
    const registry = `e2e-claude-full-${Date.now()}`;

    await withTempEnv(
      {
        VICHE_REGISTRY_URL: BASE_URL,
        VICHE_REGISTRY_TOKEN: `global,${registry}`,
        VICHE_AGENT_NAME: `claude-e2e-full-${Date.now()}`,
      },
      async () => {
        const isolated = await createIsolatedSession(`?full=${Date.now()}`);

        try {
          const isolatedAgentId = isolated.vicheServer.getAgentId();
          expect(isolatedAgentId).toBeTruthy();

          const result = await isolated.client.callTool({
            name: "viche_deregister",
            arguments: {},
          });
          expect(getToolText(result)).toContain("Deregistered from all registries");

          const globalAgents = await discover("*", "global");
          const privateAgents = await discover("*", registry);
          const allAgents = await discover("*");

          expect(globalAgents.some((a) => a.id === isolatedAgentId)).toBeFalse();
          expect(privateAgents.some((a) => a.id === isolatedAgentId)).toBeFalse();
          expect(allAgents.some((a) => a.id === isolatedAgentId)).toBeFalse();
        } finally {
          await closeSession(isolated);
        }
      }
    );
  }, 90_000);

  it("7) inbound HTTP message is delivered as MCP notification", async () => {
    const senderId = await registerAgent(["e2e-inbound-sender"], `sender-${Date.now()}`);

    const notificationSchema = z.object({
      method: z.literal("notifications/claude/channel"),
      params: z.object({
        content: z.string(),
        meta: z.object({
          message_id: z.string(),
          from: z.string(),
          type: z.string(),
        }),
      }),
    });

    const incoming = new Promise<{
      content: string;
      from: string;
      type: string;
    }>((resolve) => {
      session.client.setNotificationHandler(notificationSchema, (notification) => {
        resolve({
          content: notification.params.content,
          from: notification.params.meta.from,
          type: notification.params.meta.type,
        });
      });
    });

    const messageResp = await fetch(`${BASE_URL}/messages/${agentId}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Agent-ID": senderId,
      },
      body: JSON.stringify({
        type: "task",
        body: "inbound delivery test",
      }),
    });
    expect(messageResp.ok).toBeTrue();

    const notification = await Promise.race([
      incoming,
      wait(2_000).then(() => {
        throw new Error("Timed out waiting for notifications/claude/channel");
      }),
    ]);

    expect(notification.content).toContain("inbound delivery test");
    expect(notification.content).toContain(`[Task from ${senderId}]`);
    expect(notification.from).toBe(senderId);
    expect(notification.type).toBe("task");
  });

  it("8) cleanup removes agent from discovery after grace period", async () => {
    const cleanupSession = await createSession();
    const cleanupAgentId = cleanupSession.vicheServer.getAgentId();

    expect(cleanupAgentId).toBeTruthy();
    cleanupSession.vicheServer.cleanup();
    await cleanupSession.client.close();
    await cleanupSession.vicheServer.server.close();

    const disappeared = await waitForAgentAbsence(cleanupAgentId!, 70_000);
    expect(disappeared).toBeTrue();
  }, 90_000);

  it("9) invalid VICHE_REGISTRY_URL makes waitForReady fail", async () => {
    await withTempEnv(
      {
        VICHE_REGISTRY_URL: "http://localhost:99999",
        VICHE_AGENT_NAME: `claude-e2e-invalid-${Date.now()}`,
      },
      async () => {
        const badSessionPromise = createIsolatedSession(`?invalid=${Date.now()}`);

        try {
          await expect(badSessionPromise).rejects.toThrow();
        } finally {
          // No-op: failed session creation has no connected MCP client/server handles to close.
        }
      }
    );
  }, 90_000);
});
