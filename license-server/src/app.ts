import fastify from "fastify";
import cors from "@fastify/cors";
import type { PrismaClient } from "@prisma/client";
import type { AppConfig } from "./config.js";
import { healthRoutes } from "./routes/health.js";
import { licenseRoutes } from "./routes/licenses.js";
import { AuditEventService } from "./services/AuditEventService.js";
import { RateLimitService } from "./services/RateLimitService.js";
import { CertificateService } from "./services/CertificateService.js";
import { DeviceProofService } from "./services/DeviceProofService.js";
import { ActivationService } from "./services/ActivationService.js";
import { LicenseService } from "./services/LicenseService.js";

export function buildServices(prisma: PrismaClient, config: AppConfig) {
  const audit = new AuditEventService(prisma);
  const certificates = new CertificateService(prisma, config);
  const deviceProof = new DeviceProofService(config);
  return {
    audit,
    rateLimit: new RateLimitService(config.rateLimitEnabled),
    certificates,
    deviceProof,
    activation: new ActivationService(prisma, config, audit, certificates, deviceProof),
    licenses: new LicenseService(prisma, config, audit)
  };
}

declare module "fastify" {
  interface FastifyInstance {
    licenseServices: ReturnType<typeof buildServices>;
  }
}

export async function buildApp(prisma: PrismaClient, config: AppConfig) {
  const app = fastify({
    logger: {
      level: process.env.LOG_LEVEL ?? "info",
      redact: [
        "req.body.licenseCode",
        "req.body.deviceProof.signature",
        "req.body.signature",
        "licenseCode",
        "signature"
      ]
    }
  });

  await app.register(cors, { origin: false });
  app.decorate("licenseServices", buildServices(prisma, config));
  await app.register(healthRoutes);
  await app.register(licenseRoutes);
  return app;
}
