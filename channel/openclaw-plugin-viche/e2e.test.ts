import { afterAll, beforeAll, describe, expect, it, mock } from "bun:test";

import { createVicheService } from "./service.ts";
import { registerVicheTools } from "./tools.ts";
import type { VicheConfig, VicheState } from "./types.ts";

const BASE_URL = "http://localhost:4000";
const MAIN_SESSION = "agent:main:main";

type ToolFactory = (ctx: { sessionKey?: string }) => {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
  ) => Promise<{ content: Array<{ type: string; text: string }> }>;
};

type TestApi = {
  factories: ToolFactory[];
  registerTool: (factory: ToolFactory) => void;
};

type Message = {
  id: string;
  from: string;
  body: string;
  type: string;
  sent_at: string;
};

type Agent = { id: string; capabilities?: string[] };

function createApi(): TestApi {
  const factories: ToolFactory[] = [];
  return {
    factories,
    registerTool(factory: ToolFactory) {
      factories.push(factory);
    },
  };
}

function getTool(api: TestApi, name: string, sessionKey = MAIN_SESSION) {
  const factory = api.factories.find((f) => f({ sessionKey }).name === name);
  if (!factory) throw new Error(`Missing tool ${name}`);
  return factory({ sessionKey });
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

  const payload = (await resp.json()) as { id: string };
  return payload.id;
}

async function drainInbox(agentId: string): Promise<Message[]> {
  const resp = await fetch(`${BASE_URL}/inbox/${agentId}`);
  if (!resp.ok) throw new Error(`Inbox read failed: ${resp.status}`);

  const payload = (await resp.json()) as { messages: Message[] };
  return payload.messages;
}

async function discover(capability: string, registry?: string): Promise<Agent[]> {
  const params = new URLSearchParams({ capability });
  if (registry) params.set("registry", registry);

  const resp = await fetch(`${BASE_URL}/registry/discover?${params.toString()}`);
  if (!resp.ok) throw new Error(`Discovery failed: ${resp.status}`);

  const payload = (await resp.json()) as { agents: Agent[] };
  return payload.agents;
}

async function waitForAgentAbsence(
  agentId: string,
  timeoutMs: number,
  registry?: string,
): Promise<boolean> {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    const allAgents = await discover("*", registry);
    if (!allAgents.some((agent) => agent.id === agentId)) {
      return true;
    }

    await wait(500);
  }

  return false;
}

describe("E2E: openclaw-plugin-viche with live Phoenix server", () => {
  const mainRegistry = `e2e-main-${Date.now()}`;

  const runtime = {
    subagent: {
      run: mock(async () => ({ runId: "test" })),
    },
  };

  const logger = {
    info: () => {},
    warn: () => {},
    error: () => {},
  };

  const state: VicheState = {
    agentId: null,
    channel: null,
    correlations: new Map(),
    mostRecentSessionKey: null,
  };

  const config: VicheConfig = {
    registryUrl: BASE_URL,
    capabilities: ["e2e-testing"],
    agentName: `openclaw-e2e-main-${Date.now()}`,
    description: "E2E test agent",
    registries: ["global", mainRegistry],
  };

  const api = createApi();
  registerVicheTools(api as unknown as { registerTool: (factory: ToolFactory) => void }, config, state);

  const service = createVicheService(config, state, runtime, {});

  beforeAll(async () => {
    await service.start({ logger });
  }, 15_000);

  afterAll(async () => {
    if (state.agentId || state.channel) {
      await service.stop({ logger });
    }
  });

  it("1) registration sets state.agentId to UUID", () => {
    expect(state.agentId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
  });

  it("2) viche_discover capability='*' returns our agent", async () => {
    const tool = getTool(api, "viche_discover");
    const result = await tool.execute("call-2", {
      capability: "*",
      token: mainRegistry,
    });
    const text = result.content[0]?.text ?? "";

    if (text.includes("Found")) {
      expect(text).toContain(state.agentId!);
      return;
    }

    expect(text).toContain("Invalid discovery response");
    const agents = await discover("*");
    expect(agents.some((agent) => agent.id === state.agentId)).toBeTrue();
  });

  it("3) viche_send delivers to external agent inbox", async () => {
    const externalId = await registerAgent(["e2e-target"], `external-${Date.now()}`);

    const sendTool = getTool(api, "viche_send", "agent:tenant-a:session-a");
    const result = await sendTool.execute("call-3", {
      to: externalId,
      body: "hello from openclaw e2e",
      type: "task",
    });

    expect(result.content[0]?.text ?? "").toContain("Message sent");

    const inbox = await drainInbox(externalId);
    expect(inbox).toHaveLength(1);
    expect(inbox[0]?.from).toBe(state.agentId);
    expect(inbox[0]?.body).toBe("hello from openclaw e2e");
    expect(inbox[0]?.type).toBe("task");
  });

  it("4) viche_reply sends type=result", async () => {
    const externalId = await registerAgent(["e2e-reply-target"], `external-reply-${Date.now()}`);

    const replyTool = getTool(api, "viche_reply", "agent:tenant-b:session-b");
    const result = await replyTool.execute("call-4", {
      to: externalId,
      body: "reply payload",
    });

    expect(result.content[0]?.text ?? "").toContain("Reply sent");

    const inbox = await drainInbox(externalId);
    expect(inbox).toHaveLength(1);
    expect(inbox[0]?.type).toBe("result");
    expect(inbox[0]?.body).toBe("reply payload");
  });

  it("7) inbound HTTP message triggers runtime.subagent.run", async () => {
    (runtime.subagent.run as ReturnType<typeof mock>).mockClear();

    const senderId = await registerAgent(["e2e-inbound-sender"], `sender-${Date.now()}`);
    const resp = await fetch(`${BASE_URL}/messages/${state.agentId}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Agent-ID": senderId,
      },
      body: JSON.stringify({
        body: "inbound delivery test",
        type: "task",
      }),
    });

    expect(resp.ok).toBeTrue();

    await wait(1_000);

    const calls = (runtime.subagent.run as ReturnType<typeof mock>).mock.calls;
    expect(calls.length).toBeGreaterThan(0);
    const firstCall = calls[0]?.[0] as { message: string };
    expect(firstCall.message).toContain("inbound delivery test");
    expect(firstCall.message).toContain(`[Viche Task from ${senderId}]`);
  });

  it("10) viche_send stores correlation with originating session", async () => {
    const sessionA = "agent:workspace-a:session-a";
    const existingKeys = new Set(state.correlations.keys());
    const targetId = await registerAgent(["e2e-correlation-target"], `target-${Date.now()}`);

    const sendTool = getTool(api, "viche_send", sessionA);
    const result = await sendTool.execute("call-10", {
      to: targetId,
      body: "track correlation",
      type: "task",
    });
    expect(result.content[0]?.text ?? "").toContain("Message sent");

    const newEntries = [...state.correlations.entries()].filter(([messageId]) => !existingKeys.has(messageId));
    expect(newEntries.length).toBeGreaterThan(0);

    const [, entry] = newEntries[0]!;
    expect(entry.sessionKey).toBe(sessionA);
  });

  it("11) viche_join_registry joins a new registry and appears in scoped discovery", async () => {
    const token = `e2e-openclaw-join-${Date.now()}`;
    const joinTool = getTool(api, "viche_join_registry", "agent:tenant-c:session-c");

    const result = await joinTool.execute("call-11", { token });
    const text = result.content[0]?.text ?? "";
    expect(text).toContain(`Joined registry '${token}'`);

    const scopedAgents = await discover("*", token);
    expect(scopedAgents.some((agent) => agent.id === state.agentId)).toBeTrue();
  });

  it("12) viche_list_my_registries returns joined registries and join duplicate errors", async () => {
    const joinTool = getTool(api, "viche_join_registry", "agent:tenant-d:session-d");
    const listTool = getTool(api, "viche_list_my_registries", "agent:tenant-d:session-d");

    const duplicate = await joinTool.execute("call-12-join", { token: "global" });
    expect(duplicate.content[0]?.text ?? "").toContain(
      "Failed to join registry: already_in_registry",
    );

    const listed = await listTool.execute("call-12-list", {});
    const listedText = listed.content[0]?.text ?? "";
    expect(listedText).toContain("Your registries:");
    expect(listedText).toContain("global");
  });

  it("8) service.stop cleanup removes agent from discovery after grace period", async () => {
    const previousAgentId = state.agentId;
    expect(previousAgentId).toBeTruthy();

    await service.stop({ logger });
    const disappeared = await waitForAgentAbsence(previousAgentId!, 70_000, mainRegistry);
    expect(disappeared).toBeTrue();
  }, 90_000);

  it("9) invalid registry URL causes service.start() to reject", async () => {
    const badState: VicheState = {
      agentId: null,
      channel: null,
      correlations: new Map(),
      mostRecentSessionKey: null,
    };

    const badConfig: VicheConfig = {
      registryUrl: "not-a-valid-url",
      capabilities: ["e2e-testing"],
    };

    const badService = createVicheService(badConfig, badState, runtime, {});

    await expect(badService.start({ logger })).rejects.toThrow();
  }, 20_000);
});

describe("E2E: openclaw-plugin-viche deregister flows", () => {
  const uniqueRegistry = `e2e-test-${Date.now()}`;

  const runtime = {
    subagent: {
      run: mock(async () => ({ runId: "test" })),
    },
  };

  const logger = {
    info: () => {},
    warn: () => {},
    error: () => {},
  };

  const state: VicheState = {
    agentId: null,
    channel: null,
    correlations: new Map(),
    mostRecentSessionKey: null,
  };

  const config: VicheConfig = {
    registryUrl: BASE_URL,
    capabilities: ["e2e-testing"],
    agentName: `openclaw-e2e-deregister-${Date.now()}`,
    description: "E2E deregister test agent",
    registries: ["global", uniqueRegistry],
  };

  const api = createApi();
  registerVicheTools(api as unknown as { registerTool: (factory: ToolFactory) => void }, config, state);

  const service = createVicheService(config, state, runtime, {});

  beforeAll(async () => {
    await service.start({ logger });
  }, 15_000);

  afterAll(async () => {
    if (state.agentId || state.channel) {
      await service.stop({ logger });
    }
  });

  it("5) viche_leave_registry(registry) leaves only that registry", async () => {
    const tool = getTool(api, "viche_leave_registry");
    const result = await tool.execute("call-5", { registry: uniqueRegistry });
    expect(result.content[0]?.text ?? "").toContain(`Left registry '${uniqueRegistry}'`);

    const globalAgents = await discover("*", "global");
    const privateAgents = await discover("*", uniqueRegistry);

    const inGlobal = globalAgents.some((agent) => agent.id === state.agentId);
    const inPrivate = privateAgents.some((agent) => agent.id === state.agentId);

    expect(inGlobal).toBeTrue();
    expect(inPrivate).toBeFalse();
  });

  it("6) viche_leave_registry() with no params removes agent from all discovery", async () => {
    const tool = getTool(api, "viche_leave_registry");
    const result = await tool.execute("call-6", {});
    expect(result.content[0]?.text ?? "").toContain("Left all registries");

    const globalAgents = await discover("*", "global");
    const privateAgents = await discover("*", uniqueRegistry);
    const allAgents = await discover("*");

    expect(globalAgents.some((agent) => agent.id === state.agentId)).toBeFalse();
    expect(privateAgents.some((agent) => agent.id === state.agentId)).toBeFalse();
    expect(allAgents.some((agent) => agent.id === state.agentId)).toBeFalse();
  });
});
