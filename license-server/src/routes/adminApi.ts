import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { AppConfig } from "../config.js";
import { AdminAPIError, AdminAuthService, type AdminContext } from "../services/AdminAuthService.js";
import { RateLimitError } from "../services/RateLimitService.js";

type AdminRequest = FastifyRequest & { adminContext?: AdminContext };

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1)
});

const createLicenseSchema = z.object({
  email: z.string().trim().email(),
  plan: z.string().trim().min(1).max(80).default("pro_lifetime"),
  seats: z.coerce.number().int().min(1).max(99).default(2),
  orderProvider: z.string().trim().max(80).optional(),
  orderId: z.string().trim().max(120).optional()
}).superRefine((value, ctx) => {
  if (Boolean(value.orderProvider) !== Boolean(value.orderId)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: "orderProvider 和 orderId 必须同时填写或同时留空。"
    });
  }
});

const versionedActionSchema = z.object({
  expectedVersion: z.coerce.number().int().min(0),
  reason: z.string().trim().min(1).max(200)
});

const seatLimitSchema = versionedActionSchema.extend({
  seatLimit: z.coerce.number().int().min(1).max(999)
});

const adminUserSchema = z.object({
  email: z.string().trim().email(),
  password: z.string().min(8).max(200)
});

const adminPasswordSchema = z.object({
  password: z.string().min(8).max(200)
});

function pagination(query: Record<string, unknown>): { page: number; pageSize: number } {
  return {
    page: Math.max(1, Number(query.page ?? "1") || 1),
    pageSize: Math.min(100, Math.max(1, Number(query.pageSize ?? "20") || 20))
  };
}

function cookies(header: string | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  for (const part of header?.split(";") ?? []) {
    const index = part.indexOf("=");
    if (index <= 0) continue;
    result[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return result;
}

function cookieHeader(token: string, config: AppConfig): string {
  const secure = config.nodeEnv === "production" ? "; Secure" : "";
  return `${AdminAuthService.cookieName}=${encodeURIComponent(token)}; Path=/admin-api; Max-Age=43200; HttpOnly; SameSite=Strict${secure}`;
}

function clearCookieHeader(config: AppConfig): string {
  const secure = config.nodeEnv === "production" ? "; Secure" : "";
  return `${AdminAuthService.cookieName}=; Path=/admin-api; Max-Age=0; HttpOnly; SameSite=Strict${secure}`;
}

function requestId(request: FastifyRequest): string {
  return String(request.id);
}

function success<T>(request: FastifyRequest, data: T): { ok: true; data: T; requestId: string } {
  return { ok: true, data, requestId: requestId(request) };
}

function fail(reply: FastifyReply, request: FastifyRequest, statusCode: number, code: string, message: string, data?: unknown): void {
  reply.code(statusCode).send({
    ok: false,
    error: { code, message, ...(data === undefined ? {} : { data }) },
    requestId: requestId(request)
  });
}

function noStore(reply: FastifyReply): void {
  reply.header("Cache-Control", "no-store");
}

function isUnsafe(method: string): boolean {
  return method !== "GET" && method !== "HEAD" && method !== "OPTIONS";
}

function originAllowed(request: FastifyRequest, config: AppConfig): boolean {
  const origin = request.headers.origin;
  return !origin || origin === config.adminWebOrigin;
}

function tokenFromRequest(request: FastifyRequest): string | undefined {
  return cookies(request.headers.cookie)[AdminAuthService.cookieName];
}

function mapError(error: unknown): { statusCode: number; code: string; message: string; data?: unknown; retryAfter?: number } {
  if (error instanceof AdminAPIError) {
    return { statusCode: error.statusCode, code: error.code, message: error.message, data: error.data };
  }
  if (error instanceof RateLimitError) {
    return { statusCode: 429, code: "LOGIN_RATE_LIMITED", message: "登录尝试过多，请稍后再试。", retryAfter: 60 };
  }
  if (error instanceof z.ZodError) {
    return { statusCode: 400, code: "INVALID_REQUEST", message: "请求格式不正确。" };
  }
  return { statusCode: 500, code: "SERVER_ERROR", message: "后台服务暂时不可用。" };
}

export async function adminApiRoutes(app: FastifyInstance, config: AppConfig): Promise<void> {
  const adminAuth = app.licenseServices.adminAuth;

  app.addHook("onRequest", async (request, reply) => {
    if (!request.url.startsWith("/admin-api")) return;
    noStore(reply);
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("Referrer-Policy", "no-referrer");
    reply.header("Content-Security-Policy", "frame-ancestors 'none'");
    if (config.nodeEnv === "production") {
      reply.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    }
  });

  app.addHook("preHandler", async (request: AdminRequest, reply) => {
    if (!request.url.startsWith("/admin-api")) return;
    if (request.url === "/admin-api/auth/login") {
      if (!originAllowed(request, config)) {
        fail(reply, request, 403, "ORIGIN_NOT_ALLOWED", "请求来源不被允许。");
        return reply;
      }
      return;
    }

    if (isUnsafe(request.method) && !request.headers["x-csrf-token"]) {
      fail(reply, request, 403, "CSRF_TOKEN_INVALID", "安全校验失败，请刷新后重试。");
      return reply;
    }

    const context = await adminAuth.authenticate(tokenFromRequest(request)).catch(() => null);
    if (!context) {
      fail(reply, request, 401, "UNAUTHENTICATED", "请先登录后台。");
      return reply;
    }
    request.adminContext = context;

    if (isUnsafe(request.method)) {
      if (!originAllowed(request, config)) {
        fail(reply, request, 403, "ORIGIN_NOT_ALLOWED", "请求来源不被允许。");
        return reply;
      }
      const csrf = String(request.headers["x-csrf-token"] ?? "");
      if (!adminAuth.safeEqual(csrf, context.csrfToken)) {
        fail(reply, request, 403, "CSRF_TOKEN_INVALID", "安全校验失败，请刷新后重试。");
        return reply;
      }
    }
  });

  app.post("/admin-api/auth/login", async (request, reply) => {
    try {
      const body = loginSchema.parse(request.body);
      app.licenseServices.rateLimit.check(`admin-login:ip:${request.ip}`, 20, 10 * 60 * 1000);
      const accountRateLimitKey = `admin-login:email:${body.email.trim().toLowerCase()}`;
      app.licenseServices.rateLimit.check(accountRateLimitKey, 10, 10 * 60 * 1000);
      const ipHmac = adminAuth.requestHmac(request.ip);
      const userAgentHmac = adminAuth.requestHmac(request.headers["user-agent"]);
      const { token, context } = await adminAuth.login({
        email: body.email,
        password: body.password,
        requestId: requestId(request),
        ipHmac,
        userAgentHmac
      });
      app.licenseServices.rateLimit.clear(accountRateLimitKey);
      reply.header("Set-Cookie", cookieHeader(token, config));
      return success(request, {
        user: context.user,
        csrfToken: context.csrfToken
      });
    } catch (error) {
      const mapped = mapError(error);
      if (mapped.retryAfter) reply.header("Retry-After", String(mapped.retryAfter));
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/auth/logout", async (request: AdminRequest, reply) => {
    if (request.adminContext) {
      await adminAuth.logout(request.adminContext.session.id);
    }
    reply.header("Set-Cookie", clearCookieHeader(config));
    return success(request, { ok: true });
  });

  app.get("/admin-api/auth/current", async (request: AdminRequest) => {
    return success(request, { user: request.adminContext?.user });
  });

  app.get("/admin-api/auth/csrf", async (request: AdminRequest) => {
    return success(request, { csrfToken: request.adminContext?.csrfToken });
  });

  app.get("/admin-api/dashboard/summary", async (request) => {
    return success(request, await app.licenseServices.adminPortal.dashboardSummary());
  });

  app.get("/admin-api/dashboard/timeseries", async (request) => {
    const query = request.query as { days?: string };
    return success(request, await app.licenseServices.adminPortal.dashboardTimeseries(Number(query.days ?? "30") || 30));
  });

  app.get("/admin-api/licenses", async (request: AdminRequest) => {
    const query = request.query as { page?: string; pageSize?: string; email?: string; status?: string; plan?: string; orderProvider?: string };
    const { page, pageSize } = pagination(query);
    const result = await app.licenseServices.adminLicenses.listLicenses({
      page,
      pageSize,
      email: query.email,
      status: query.status,
      plan: query.plan,
      orderProvider: query.orderProvider
    });
    return success(request, result);
  });

  app.get("/admin-api/licenses/export.csv", async (_request, reply) => {
    const csv = await app.licenseServices.adminPortal.exportLicensesCsv();
    reply.header("Content-Type", "text/csv; charset=utf-8");
    reply.header("Content-Disposition", "attachment; filename=\"promptstudio-licenses.csv\"");
    return reply.send(csv);
  });

  app.post("/admin-api/licenses", async (request: AdminRequest, reply) => {
    try {
      const body = createLicenseSchema.parse(request.body);
      const idempotencyKey = request.headers["idempotency-key"];
      if (!idempotencyKey || Array.isArray(idempotencyKey)) {
        return fail(reply, request, 400, "IDEMPOTENCY_KEY_REQUIRED", "缺少 Idempotency-Key。");
      }
      const actor = request.adminContext!.user;
      const normalizedBody = {
        email: body.email.trim().toLowerCase(),
        plan: body.plan,
        seats: body.seats,
        orderProvider: body.orderProvider?.trim().toLowerCase() || undefined,
        orderId: body.orderId?.trim() || undefined
      };
      const result = await app.licenseServices.adminLicenses.createLicense({
        actor,
        ...normalizedBody,
        idempotencyKey,
        requestHash: adminAuth.requestHash(normalizedBody),
        requestId: requestId(request),
        ipHmac: adminAuth.requestHmac(request.ip),
        userAgentHmac: adminAuth.requestHmac(request.headers["user-agent"])
      });
      return success(request, result);
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.get("/admin-api/licenses/:id", async (request: AdminRequest, reply) => {
    const id = (request.params as { id: string }).id;
    const license = await app.licenseServices.adminLicenses.getLicenseDetail(id);
    if (!license) return fail(reply, request, 404, "LICENSE_NOT_FOUND", "授权不存在。");
    return success(request, license);
  });

  app.get("/admin-api/activations", async (request) => {
    const query = request.query as { page?: string; pageSize?: string; email?: string; status?: string; platform?: string; appVersion?: string };
    const { page, pageSize } = pagination(query);
    return success(request, await app.licenseServices.adminPortal.listActivations({
      page,
      pageSize,
      email: query.email,
      status: query.status,
      platform: query.platform,
      appVersion: query.appVersion
    }));
  });

  app.get("/admin-api/license-events", async (request) => {
    const query = request.query as { page?: string; pageSize?: string; eventType?: string; licenseId?: string; activationId?: string };
    const { page, pageSize } = pagination(query);
    return success(request, await app.licenseServices.adminPortal.listLicenseEvents({
      page,
      pageSize,
      eventType: query.eventType,
      licenseId: query.licenseId,
      activationId: query.activationId
    }));
  });

  app.get("/admin-api/admin-audit-logs", async (request) => {
    const query = request.query as { page?: string; pageSize?: string; action?: string; targetType?: string; targetId?: string; result?: string; adminEmail?: string };
    const { page, pageSize } = pagination(query);
    return success(request, await app.licenseServices.adminPortal.listAdminAuditLogs({
      page,
      pageSize,
      action: query.action,
      targetType: query.targetType,
      targetId: query.targetId,
      result: query.result,
      adminEmail: query.adminEmail
    }));
  });

  app.get("/admin-api/admin-users", async (request) => {
    const query = request.query as { page?: string; pageSize?: string };
    return success(request, await app.licenseServices.adminPortal.listAdminUsers(pagination(query)));
  });

  app.post("/admin-api/admin-users", async (request: AdminRequest, reply) => {
    try {
      const body = adminUserSchema.parse(request.body);
      return success(request, await app.licenseServices.adminPortal.createAdminUser({
        actor: request.adminContext!.user,
        email: body.email,
        password: body.password,
        requestId: requestId(request)
      }));
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/admin-users/:id/disable", async (request: AdminRequest, reply) => {
    try {
      await app.licenseServices.adminPortal.disableAdminUser({
        actor: request.adminContext!.user,
        adminUserId: (request.params as { id: string }).id,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/admin-users/:id/set-password", async (request: AdminRequest, reply) => {
    try {
      const body = adminPasswordSchema.parse(request.body);
      await app.licenseServices.adminPortal.setAdminPassword({
        actor: request.adminContext!.user,
        adminUserId: (request.params as { id: string }).id,
        password: body.password,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/admin-users/:id/revoke-sessions", async (request: AdminRequest, reply) => {
    try {
      await app.licenseServices.adminPortal.revokeAdminUserSessions({
        actor: request.adminContext!.user,
        adminUserId: (request.params as { id: string }).id,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.get("/admin-api/admin-sessions", async (request) => {
    const query = request.query as { page?: string; pageSize?: string; adminUserId?: string };
    const { page, pageSize } = pagination(query);
    return success(request, await app.licenseServices.adminPortal.listAdminSessions({ page, pageSize, adminUserId: query.adminUserId }));
  });

  app.post("/admin-api/admin-sessions/:id/revoke", async (request: AdminRequest, reply) => {
    try {
      await app.licenseServices.adminPortal.revokeAdminSession({
        actor: request.adminContext!.user,
        sessionId: (request.params as { id: string }).id,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.patch("/admin-api/licenses/:id/seat-limit", async (request: AdminRequest, reply) => {
    try {
      const id = (request.params as { id: string }).id;
      const body = seatLimitSchema.parse(request.body);
      await app.licenseServices.adminLicenses.setSeatLimit({
        actor: request.adminContext!.user,
        licenseId: id,
        seatLimit: body.seatLimit,
        expectedVersion: body.expectedVersion,
        reason: body.reason,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/licenses/:id/revoke", async (request: AdminRequest, reply) => {
    try {
      const id = (request.params as { id: string }).id;
      const body = versionedActionSchema.parse(request.body);
      await app.licenseServices.adminLicenses.revokeLicense({
        actor: request.adminContext!.user,
        licenseId: id,
        expectedVersion: body.expectedVersion,
        reason: body.reason,
        requestId: requestId(request)
      });
      return success(request, { ok: true });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/licenses/:id/rotate-code", async (request: AdminRequest, reply) => {
    try {
      const id = (request.params as { id: string }).id;
      const body = versionedActionSchema.parse(request.body);
      const licenseCode = await app.licenseServices.adminLicenses.rotateCode({
        actor: request.adminContext!.user,
        licenseId: id,
        expectedVersion: body.expectedVersion,
        reason: body.reason,
        requestId: requestId(request)
      });
      return success(request, { licenseCode });
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });

  app.post("/admin-api/activations/:id/deactivate", async (request: AdminRequest, reply) => {
    try {
      const activationId = (request.params as { id: string }).id;
      const body = z.object({ reason: z.string().trim().min(1).max(200).default("admin_portal") }).parse(request.body ?? {});
      const result = await app.licenseServices.adminLicenses.deactivateDevice({
        actor: request.adminContext!.user,
        activationId,
        reason: body.reason,
        requestId: requestId(request)
      });
      return success(request, result);
    } catch (error) {
      const mapped = mapError(error);
      return fail(reply, request, mapped.statusCode, mapped.code, mapped.message, mapped.data);
    }
  });
}
