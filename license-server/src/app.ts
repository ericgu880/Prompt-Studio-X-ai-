import fastify from "fastify";
import cors from "@fastify/cors";
import type { PrismaClient } from "@prisma/client";
import type { AppConfig } from "./config.js";
import { healthRoutes } from "./routes/health.js";
import { licenseRoutes } from "./routes/licenses.js";
import { adminRoutes } from "./routes/admin.js";
import { AuditEventService } from "./services/AuditEventService.js";
import { RateLimitService } from "./services/RateLimitService.js";
import { CertificateService } from "./services/CertificateService.js";
import { DeviceProofService } from "./services/DeviceProofService.js";
import { ActivationService } from "./services/ActivationService.js";
import { LicenseService } from "./services/LicenseService.js";
import { AdminAuthService } from "./services/AdminAuthService.js";
import { AdminLicenseService } from "./services/AdminLicenseService.js";
import { AdminPortalService } from "./services/AdminPortalService.js";
import { adminApiRoutes } from "./routes/adminApi.js";
import { CommerceFulfillmentService } from "./services/CommerceFulfillmentService.js";
import { CommerceInboxWorker } from "./services/CommerceInboxWorker.js";
import { commerceWebhookRoutes } from "./routes/commerceWebhooks.js";
import { EmailOutboxService } from "./services/EmailOutboxService.js";
import { EmailOutboxWorker } from "./services/EmailOutboxWorker.js";
import { RecoveryService } from "./services/RecoveryService.js";
import { emailWebhookRoutes } from "./routes/emailWebhooks.js";
import { recoveryPageRoutes } from "./routes/recoveryPage.js";

export function buildServices(prisma: PrismaClient, config: AppConfig) {
  const audit = new AuditEventService(prisma);
  const certificates = new CertificateService(prisma, config);
  const deviceProof = new DeviceProofService(config);
  const licenses = new LicenseService(prisma, config, audit);
  const commerceFulfillment = new CommerceFulfillmentService(config, licenses);
  const commerceInbox = new CommerceInboxWorker(prisma, config, commerceFulfillment);
  const emailOutbox = new EmailOutboxService(prisma, config);
  const emailWorker = new EmailOutboxWorker(prisma, config);
  const recovery = new RecoveryService(prisma, config);
  return {
    audit,
    rateLimit: new RateLimitService(config.rateLimitEnabled),
    certificates,
    deviceProof,
    activation: new ActivationService(prisma, config, audit, certificates, deviceProof),
    licenses,
    commerceFulfillment,
    commerceInbox,
    emailOutbox,
    emailWorker,
    recovery,
    adminAuth: new AdminAuthService(prisma, config),
    adminLicenses: new AdminLicenseService(prisma, config),
    adminPortal: new AdminPortalService(prisma, config)
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
  await app.register(commerceWebhookRoutes, config);
  await app.register(emailWebhookRoutes, config);
  await app.register(recoveryPageRoutes, config);
  await app.register(licenseRoutes);
  await app.register(adminApiRoutes, config);
  await app.register(adminRoutes, config);
  app.addHook("onReady", async () => {
    app.licenseServices.commerceInbox.start();
    app.licenseServices.emailWorker.start();
  });
  app.addHook("onClose", async () => {
    app.licenseServices.commerceInbox.stop();
    app.licenseServices.emailWorker.stop();
  });
  return app;
}
