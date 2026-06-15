import { loadConfig } from "./config.js";
import { prisma } from "./db/prisma.js";
import { buildApp } from "./app.js";

const config = loadConfig();
const app = await buildApp(prisma, config);

try {
  await app.listen({ host: "0.0.0.0", port: config.port });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
