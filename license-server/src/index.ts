import { loadConfig } from "./config.js";
import { prisma } from "./db/prisma.js";
import { buildApp } from "./app.js";
import { createShutdownHandler } from "./lifecycle.js";

const config = loadConfig();
const app = await buildApp(prisma, config);
const shutdown = createShutdownHandler(app, prisma);
process.once("SIGTERM", () => { void shutdown("SIGTERM"); });
process.once("SIGINT", () => { void shutdown("SIGINT"); });

try {
  await app.listen({ host: "0.0.0.0", port: config.port });
} catch (error) {
  app.log.error(error);
  await prisma.$disconnect();
  process.exit(1);
}
