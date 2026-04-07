import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createVicheServer } from "./server.js";
import {
  clearActiveConnection,
  connectAndRegisterWithRetry,
} from "./service.js";

export async function main(): Promise<void> {
  const { server } = createVicheServer();

  const transport = new StdioServerTransport();
  await server.connect(transport);
  await connectAndRegisterWithRetry(server);

  const shutdown = () => {
    clearActiveConnection();
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

if (import.meta.main) {
  main().catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Viche: fatal error — ${message}\n`);
    process.exit(1);
  });
}
