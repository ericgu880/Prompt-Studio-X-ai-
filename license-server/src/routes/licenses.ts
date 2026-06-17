import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { LicenseAPIError } from "../services/ActivationService.js";

const activateSchema = z.object({
  email: z.string().email(),
  licenseCode: z.string().min(8),
  installIdHash: z.string().min(20),
  devicePublicKey: z.string().min(40),
  deviceProof: z.object({
    version: z.literal("PromptStudio-Activate-Proof-v1"),
    clientNonce: z.string().min(20),
    createdAt: z.string().datetime(),
    signature: z.string().min(40)
  }),
  deviceLabel: z.string().min(1).max(120),
  bundleId: z.string().min(1),
  appVersion: z.string().optional(),
  osVersion: z.string().optional()
});

const challengeSchema = z.object({
  activationId: z.string().min(1)
});

const refreshSchema = z.object({
  activationId: z.string().min(1),
  challengeId: z.string().min(1),
  signature: z.string().min(40),
  appVersion: z.string().optional(),
  osVersion: z.string().optional()
});

const deactivateSchema = z.object({
  activationId: z.string().min(1),
  challengeId: z.string().min(1),
  signature: z.string().min(40),
  reason: z.string().min(1).max(80).default("user_requested")
});

const devicesListSchema = z.object({
  activationId: z.string().min(1),
  challengeId: z.string().min(1),
  signature: z.string().min(40)
});

const deviceRenameSchema = devicesListSchema.extend({
  targetActivationId: z.string().min(1),
  label: z.string().trim().min(1).max(120)
});

const deviceDeactivateSchema = devicesListSchema.extend({
  targetActivationId: z.string().min(1),
  reason: z.string().min(1).max(80).default("user_requested")
});

const recoverSchema = z.object({
  email: z.string().email()
});

function mapError(error: unknown): { statusCode: number; body: unknown } {
  if (error instanceof LicenseAPIError) {
    return {
      statusCode: error.statusCode,
      body: {
        ok: false,
        error: {
          code: error.code,
          message: error.message,
          ...(typeof error.data === "object" && error.data !== null ? error.data : {})
        }
      }
    };
  }
  if (error instanceof z.ZodError) {
    return {
      statusCode: 400,
      body: { ok: false, error: { code: "INVALID_REQUEST", message: "请求格式不正确。" } }
    };
  }
  return {
    statusCode: 500,
    body: { ok: false, error: { code: "SERVER_ERROR", message: "授权服务暂时不可用，请稍后再试。" } }
  };
}

export async function licenseRoutes(app: FastifyInstance): Promise<void> {
  const services = app.licenseServices;

  app.post("/v1/licenses/activate", async (request, reply) => {
    try {
      const body = activateSchema.parse(request.body);
      services.rateLimit.check(`activate:ip:${request.ip}`, 20, 10 * 60 * 1000);
      services.rateLimit.check(`activate:email:${body.email.toLowerCase()}`, 10, 10 * 60 * 1000);
      const response = await services.activation.activate(body);
      return { ok: true, ...response };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/refresh/challenge", async (request, reply) => {
    try {
      const body = challengeSchema.parse(request.body);
      services.rateLimit.check(`challenge:${body.activationId}`, 30, 10 * 60 * 1000);
      const response = await services.activation.createRefreshChallenge(body.activationId);
      return { ok: true, ...response };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/refresh", async (request, reply) => {
    try {
      const body = refreshSchema.parse(request.body);
      services.rateLimit.check(`refresh:${body.activationId}`, 30, 10 * 60 * 1000);
      const response = await services.activation.refresh(body);
      return { ok: true, ...response };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/deactivate", async (request, reply) => {
    try {
      const body = deactivateSchema.parse(request.body);
      services.rateLimit.check(`deactivate:${body.activationId}`, 30, 10 * 60 * 1000);
      await services.activation.deactivate(body);
      return { ok: true };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/devices/list", async (request, reply) => {
    try {
      const body = devicesListSchema.parse(request.body);
      services.rateLimit.check(`devices:list:${body.activationId}`, 30, 10 * 60 * 1000);
      const response = await services.activation.listDevices(body);
      return { ok: true, ...response };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/devices/rename", async (request, reply) => {
    try {
      const body = deviceRenameSchema.parse(request.body);
      services.rateLimit.check(`devices:rename:${body.activationId}`, 30, 10 * 60 * 1000);
      await services.activation.renameDevice(body);
      return { ok: true };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/devices/deactivate", async (request, reply) => {
    try {
      const body = deviceDeactivateSchema.parse(request.body);
      services.rateLimit.check(`devices:deactivate:${body.activationId}`, 30, 10 * 60 * 1000);
      await services.activation.deactivateDeviceById(body);
      return { ok: true };
    } catch (error) {
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });

  app.post("/v1/licenses/recover", async (request, reply) => {
    try {
      const body = recoverSchema.parse(request.body);
      services.rateLimit.check(`recover:${body.email.toLowerCase()}`, 3, 60 * 60 * 1000);
      await services.activation.recover(body.email);
      return { ok: true };
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.code(200).send({ ok: true });
      }
      const mapped = mapError(error);
      return reply.code(mapped.statusCode).send(mapped.body);
    }
  });
}
