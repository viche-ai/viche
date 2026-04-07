import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  clearActiveConnection,
  getActiveAgentId,
  getActiveChannel,
  getRegistryChannels,
} from "./service.js";
import { registerToolHandlers } from "./tools.js";

const READY_TIMEOUT_MS = 60_000;
const READY_POLL_INTERVAL_MS = 50;

export function createVicheServer(): {
  server: Server;
  getAgentId: () => string | null;
  waitForReady: () => Promise<void>;
  cleanup: () => void;
} {
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
    getActiveChannel,
    getActiveAgentId,
    getRegistryChannels
  );

  const waitForReady = async (): Promise<void> => {
    const start = Date.now();
    while (getActiveAgentId() === null) {
      if (Date.now() - start > READY_TIMEOUT_MS) {
        throw new Error("Timed out waiting for Viche registration");
      }
      await new Promise((resolve) => setTimeout(resolve, READY_POLL_INTERVAL_MS));
    }
  };

  return {
    server,
    getAgentId: getActiveAgentId,
    waitForReady,
    cleanup: clearActiveConnection,
  };
}
