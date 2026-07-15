import type { AdminSession, AdminUser, Prisma, PrismaClient } from "@prisma/client";
import { hash } from "bcryptjs";
import type { AppConfig } from "../config.js";
import { hashEmail, normalizeEmail } from "../crypto/email.js";
import { AdminAPIError } from "./AdminAuthService.js";
import type { AdminActor } from "./AdminLicenseService.js";

interface PageInput {
  page: number;
  pageSize: number;
}

function startOfToday(): Date {
  const date = new Date();
  date.setHours(0, 0, 0, 0);
  return date;
}

function truncateHmac(value: string | null): string | null {
  return value ? `${value.slice(0, 12)}...` : null;
}

function pageResult<T>(items: T[], page: number, pageSize: number, total: number) {
  return { items, page, pageSize, total };
}

function csvCell(value: unknown): string {
  const text = value == null ? "" : String(value);
  return `"${text.replace(/"/g, '""')}"`;
}

export class AdminPortalService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig
  ) {}

  async dashboardSummary(): Promise<{
    totalLicenses: number;
    todayNewLicenses: number;
    todayActivationSuccess: number;
    todayActivationFailed: number;
    activeDevices: number;
    revokedLicenses: number;
    totalSeats: number;
    seatUsageRate: number;
  }> {
    const today = startOfToday();
    const [
      totalLicenses,
      todayNewLicenses,
      revokedLicenses,
      activeDevices,
      todayActivationSuccess,
      todayActivationFailed,
      seatAggregate
    ] = await Promise.all([
      this.prisma.license.count(),
      this.prisma.license.count({ where: { createdAt: { gte: today } } }),
      this.prisma.license.count({ where: { status: "revoked" } }),
      this.prisma.activation.count({ where: { status: "active" } }),
      this.prisma.licenseEvent.count({ where: { eventType: "activation_success", createdAt: { gte: today } } }),
      this.prisma.licenseEvent.count({ where: { eventType: "activation_failed", createdAt: { gte: today } } }),
      this.prisma.license.aggregate({ _sum: { seatLimit: true } })
    ]);
    const totalSeats = seatAggregate._sum.seatLimit ?? 0;
    return {
      totalLicenses,
      todayNewLicenses,
      todayActivationSuccess,
      todayActivationFailed,
      activeDevices,
      revokedLicenses,
      totalSeats,
      seatUsageRate: totalSeats > 0 ? Number((activeDevices / totalSeats).toFixed(4)) : 0
    };
  }

  async dashboardTimeseries(days: number): Promise<Array<{
    date: string;
    licenseCreated: number;
    activationSuccess: number;
    activationFailed: number;
    refreshSuccess: number;
    licenseRevoked: number;
  }>> {
    const safeDays = Math.min(30, Math.max(7, days));
    const since = new Date();
    since.setHours(0, 0, 0, 0);
    since.setDate(since.getDate() - safeDays + 1);
    const events = await this.prisma.licenseEvent.findMany({
      where: {
        createdAt: { gte: since },
        eventType: { in: ["license_created", "activation_success", "activation_failed", "refresh_success", "license_revoked"] }
      },
      select: { eventType: true, createdAt: true },
      orderBy: { createdAt: "asc" }
    });
    const rows = new Map<string, {
      date: string;
      licenseCreated: number;
      activationSuccess: number;
      activationFailed: number;
      refreshSuccess: number;
      licenseRevoked: number;
    }>();
    for (let index = 0; index < safeDays; index += 1) {
      const date = new Date(since);
      date.setDate(since.getDate() + index);
      const key = date.toISOString().slice(0, 10);
      rows.set(key, { date: key, licenseCreated: 0, activationSuccess: 0, activationFailed: 0, refreshSuccess: 0, licenseRevoked: 0 });
    }
    for (const event of events) {
      const key = event.createdAt.toISOString().slice(0, 10);
      const row = rows.get(key);
      if (!row) continue;
      if (event.eventType === "license_created") row.licenseCreated += 1;
      if (event.eventType === "activation_success") row.activationSuccess += 1;
      if (event.eventType === "activation_failed") row.activationFailed += 1;
      if (event.eventType === "refresh_success") row.refreshSuccess += 1;
      if (event.eventType === "license_revoked") row.licenseRevoked += 1;
    }
    return [...rows.values()];
  }

  async listActivations(input: PageInput & {
    email?: string;
    status?: string;
    platform?: string;
    appVersion?: string;
  }) {
    const where: Prisma.ActivationWhereInput = {
      ...(input.status ? { status: input.status as Prisma.EnumActivationStatusFilter<"Activation"> } : {}),
      ...(input.platform ? { platform: input.platform } : {}),
      ...(input.appVersion ? { appVersion: input.appVersion } : {}),
      ...(input.email ? { license: { customer: { emailHash: hashEmail(this.config.licenseCodePepper, normalizeEmail(input.email)) } } } : {})
    };
    const [total, activations] = await this.prisma.$transaction([
      this.prisma.activation.count({ where }),
      this.prisma.activation.findMany({
        where,
        include: { license: { include: { customer: true } } },
        orderBy: { activatedAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize
      })
    ]);
    return pageResult(activations.map((activation) => ({
      id: activation.id,
      licenseId: activation.licenseId,
      email: activation.license.customer.emailMasked,
      code: activation.license.codeMasked,
      plan: activation.license.plan,
      licenseStatus: activation.license.status,
      label: activation.deviceLabel,
      status: activation.status,
      platform: activation.platform,
      appVersion: activation.appVersion,
      osVersion: activation.osVersion,
      activatedAt: activation.activatedAt,
      lastSeenAt: activation.lastSeenAt,
      deactivatedAt: activation.deactivatedAt,
      deactivatedReason: activation.deactivatedReason
    })), input.page, input.pageSize, total);
  }

  async listLicenseEvents(input: PageInput & { eventType?: string; licenseId?: string; activationId?: string }) {
    const where: Prisma.LicenseEventWhereInput = {
      ...(input.eventType ? { eventType: input.eventType } : {}),
      ...(input.licenseId ? { licenseId: input.licenseId } : {}),
      ...(input.activationId ? { activationId: input.activationId } : {})
    };
    const [total, events] = await this.prisma.$transaction([
      this.prisma.licenseEvent.count({ where }),
      this.prisma.licenseEvent.findMany({
        where,
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize
      })
    ]);
    return pageResult(events.map((event) => ({
      id: event.id,
      licenseId: event.licenseId,
      activationId: event.activationId,
      eventType: event.eventType,
      eventSource: event.eventSource,
      codePrefix: event.codePrefix,
      metadataJson: event.metadataJson,
      createdAt: event.createdAt
    })), input.page, input.pageSize, total);
  }

  async commercialHealth() {
    const now = new Date();
    const [commercePending, commerceFailed, emailPending, emailFailed, activeRecoveryRequests] = await Promise.all([
      this.prisma.commerceWebhookEvent.count({ where: { status: { in: ["pending", "processing"] } } }),
      this.prisma.commerceWebhookEvent.count({ where: { status: "failed" } }),
      this.prisma.emailOutbox.count({ where: { status: { in: ["pending", "processing"] } } }),
      this.prisma.emailOutbox.count({ where: { status: { in: ["failed", "bounced"] } } }),
      this.prisma.licenseRecoveryToken.count({ where: { consumedAt: null, expiresAt: { gt: now } } }),
    ]);
    return { commercePending, commerceFailed, emailPending, emailFailed, activeRecoveryRequests };
  }

  async listCommerceEvents(input: PageInput & { provider?: string; eventName?: string; status?: string }) {
    const where: Prisma.CommerceWebhookEventWhereInput = {
      ...(input.provider ? { provider: input.provider } : {}),
      ...(input.eventName ? { eventName: input.eventName } : {}),
      ...(input.status ? { status: input.status as Prisma.CommerceWebhookEventWhereInput["status"] } : {}),
    };
    const [total, events] = await this.prisma.$transaction([
      this.prisma.commerceWebhookEvent.count({ where }),
      this.prisma.commerceWebhookEvent.findMany({
        where,
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize,
      }),
    ]);
    return pageResult(events.map((event) => ({
      id: event.id,
      provider: event.provider,
      eventName: event.eventName,
      providerEventId: event.providerEventId,
      status: event.status,
      attemptCount: event.attemptCount,
      nextAttemptAt: event.nextAttemptAt,
      processedAt: event.processedAt,
      lastErrorCode: event.lastErrorCode,
      lastErrorMessage: event.lastErrorMessage,
      createdAt: event.createdAt,
    })), input.page, input.pageSize, total);
  }

  async replayCommerceEvent(input: { actor: AdminActor; eventId: string; reason: string; requestId: string }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const event = await tx.commerceWebhookEvent.findUnique({ where: { id: input.eventId } });
      if (!event) throw new AdminAPIError("COMMERCE_EVENT_NOT_FOUND", 404, "支付事件不存在。");
      if (event.status !== "failed") throw new AdminAPIError("COMMERCE_EVENT_NOT_REPLAYABLE", 409, "只有失败事件可以重放。");
      await tx.commerceWebhookEvent.update({
        where: { id: event.id },
        data: {
          status: "pending",
          attemptCount: 0,
          nextAttemptAt: new Date(),
          leaseExpiresAt: null,
          processedAt: null,
          lastErrorCode: null,
          lastErrorMessage: null,
        },
      });
      await this.adminAudit(tx, input.actor, "commerce_event_replayed", "commerce_event", event.id, "success", input.requestId, {
        reason: input.reason,
        provider: event.provider,
        eventName: event.eventName,
      });
    });
  }

  async listEmailOutbox(input: PageInput & { kind?: string; status?: string; email?: string }) {
    const where: Prisma.EmailOutboxWhereInput = {
      ...(input.kind ? { kind: input.kind } : {}),
      ...(input.status ? { status: input.status as Prisma.EmailOutboxWhereInput["status"] } : {}),
      ...(input.email ? { recipientHash: hashEmail(this.config.licenseCodePepper, normalizeEmail(input.email)) } : {}),
    };
    const [total, messages] = await this.prisma.$transaction([
      this.prisma.emailOutbox.count({ where }),
      this.prisma.emailOutbox.findMany({
        where,
        include: { license: { include: { customer: true } } },
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize,
      }),
    ]);
    return pageResult(messages.map((message) => ({
      id: message.id,
      kind: message.kind,
      licenseId: message.licenseId,
      email: message.license?.customer.emailMasked ?? "-",
      status: message.status,
      provider: message.provider,
      providerMessageId: message.providerMessageId,
      attemptCount: message.attemptCount,
      payloadAvailable: Boolean(message.payloadEncrypted),
      nextAttemptAt: message.nextAttemptAt,
      acceptedAt: message.acceptedAt,
      deliveredAt: message.deliveredAt,
      lastErrorCode: message.lastErrorCode,
      lastErrorMessage: message.lastErrorMessage,
      createdAt: message.createdAt,
    })), input.page, input.pageSize, total);
  }

  async retryEmail(input: { actor: AdminActor; outboxId: string; reason: string; requestId: string }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const message = await tx.emailOutbox.findUnique({ where: { id: input.outboxId } });
      if (!message) throw new AdminAPIError("EMAIL_NOT_FOUND", 404, "邮件任务不存在。");
      if (message.status !== "failed") throw new AdminAPIError("EMAIL_NOT_RETRYABLE", 409, "只有发送失败的邮件可以重试。");
      if (!message.payloadEncrypted) throw new AdminAPIError("EMAIL_PAYLOAD_UNAVAILABLE", 409, "敏感正文已清除，请让用户重新发起找回。");
      await tx.emailOutbox.update({
        where: { id: message.id },
        data: {
          status: "pending",
          attemptCount: 0,
          nextAttemptAt: new Date(),
          leaseExpiresAt: null,
          lastErrorCode: null,
          lastErrorMessage: null,
        },
      });
      await this.adminAudit(tx, input.actor, "email_retried", "email_outbox", message.id, "success", input.requestId, {
        reason: input.reason,
        kind: message.kind,
      });
    });
  }

  async listRecoveryRequests(input: PageInput & { status?: string; email?: string }) {
    const now = new Date();
    const statusWhere: Prisma.LicenseRecoveryTokenWhereInput = input.status === "active"
      ? { consumedAt: null, expiresAt: { gt: now } }
      : input.status === "consumed"
        ? { consumedAt: { not: null } }
        : input.status === "expired"
          ? { consumedAt: null, expiresAt: { lte: now } }
          : {};
    const where: Prisma.LicenseRecoveryTokenWhereInput = {
      ...statusWhere,
      ...(input.email ? { requestEmailHash: hashEmail(this.config.licenseCodePepper, normalizeEmail(input.email)) } : {}),
    };
    const [total, tokens] = await this.prisma.$transaction([
      this.prisma.licenseRecoveryToken.count({ where }),
      this.prisma.licenseRecoveryToken.findMany({
        where,
        include: { license: { include: { customer: true } }, emailOutbox: true },
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize,
      }),
    ]);
    return pageResult(tokens.map((token) => ({
      id: token.id,
      licenseId: token.licenseId,
      email: token.license.customer.emailMasked,
      status: token.consumedAt ? "consumed" : token.expiresAt <= now ? "expired" : "active",
      emailStatus: token.emailOutbox?.status ?? null,
      expiresAt: token.expiresAt,
      consumedAt: token.consumedAt,
      createdAt: token.createdAt,
    })), input.page, input.pageSize, total);
  }

  async listAdminAuditLogs(input: PageInput & { action?: string; targetType?: string; targetId?: string; result?: string; adminEmail?: string }) {
    const where: Prisma.AdminAuditLogWhereInput = {
      ...(input.action ? { action: input.action } : {}),
      ...(input.targetType ? { targetType: input.targetType } : {}),
      ...(input.targetId ? { targetId: input.targetId } : {}),
      ...(input.result ? { result: input.result } : {}),
      ...(input.adminEmail ? { adminUser: { email: normalizeEmail(input.adminEmail) } } : {})
    };
    const [total, logs] = await this.prisma.$transaction([
      this.prisma.adminAuditLog.count({ where }),
      this.prisma.adminAuditLog.findMany({
        where,
        include: { adminUser: true },
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize
      })
    ]);
    return pageResult(logs.map((log) => ({
      id: log.id,
      adminUserId: log.adminUserId,
      adminEmail: log.adminUser?.email ?? log.actorSnapshot,
      action: log.action,
      targetType: log.targetType,
      targetId: log.targetId,
      result: log.result,
      reason: log.reason,
      requestId: log.requestId,
      ipHmac: truncateHmac(log.ipHmac),
      userAgentHmac: truncateHmac(log.userAgentHmac),
      metadataJson: log.metadataJson,
      createdAt: log.createdAt
    })), input.page, input.pageSize, total);
  }

  async listAdminUsers(input: PageInput) {
    const [total, users] = await this.prisma.$transaction([
      this.prisma.adminUser.count(),
      this.prisma.adminUser.findMany({ orderBy: { createdAt: "desc" }, skip: (input.page - 1) * input.pageSize, take: input.pageSize })
    ]);
    return pageResult(users.map((user) => this.adminUserDTO(user)), input.page, input.pageSize, total);
  }

  async createAdminUser(input: { actor: AdminActor; email: string; password: string; requestId: string }) {
    const email = normalizeEmail(input.email);
    const passwordHash = await hash(input.password, 12);
    return this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.create({ data: { email, passwordHash } });
      await this.adminAudit(tx, input.actor, "admin_user_created", "admin_user", user.id, "success", input.requestId, { email });
      return this.adminUserDTO(user);
    });
  }

  async disableAdminUser(input: { actor: AdminActor; adminUserId: string; requestId: string }) {
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.update({ where: { id: input.adminUserId }, data: { disabledAt: new Date() } });
      await tx.adminSession.updateMany({ where: { adminUserId: user.id, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.adminAudit(tx, input.actor, "admin_user_disabled", "admin_user", user.id, "success", input.requestId, { email: user.email });
    });
  }

  async setAdminPassword(input: { actor: AdminActor; adminUserId: string; password: string; requestId: string }) {
    const passwordHash = await hash(input.password, 12);
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.update({ where: { id: input.adminUserId }, data: { passwordHash, passwordChangedAt: new Date() } });
      await tx.adminSession.updateMany({ where: { adminUserId: user.id, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.adminAudit(tx, input.actor, "admin_password_changed", "admin_user", user.id, "success", input.requestId, { email: user.email });
    });
  }

  async revokeAdminUserSessions(input: { actor: AdminActor; adminUserId: string; requestId: string }) {
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.findUnique({ where: { id: input.adminUserId } });
      if (!user) throw new AdminAPIError("ADMIN_USER_NOT_FOUND", 404, "管理员不存在。");
      await tx.adminSession.updateMany({ where: { adminUserId: user.id, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.adminAudit(tx, input.actor, "admin_sessions_revoked", "admin_user", user.id, "success", input.requestId, { email: user.email });
    });
  }

  async listAdminSessions(input: PageInput & { adminUserId?: string }) {
    const where: Prisma.AdminSessionWhereInput = {
      ...(input.adminUserId ? { adminUserId: input.adminUserId } : {})
    };
    const [total, sessions] = await this.prisma.$transaction([
      this.prisma.adminSession.count({ where }),
      this.prisma.adminSession.findMany({
        where,
        include: { adminUser: true },
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize
      })
    ]);
    return pageResult(sessions.map((session) => this.adminSessionDTO(session)), input.page, input.pageSize, total);
  }

  async revokeAdminSession(input: { actor: AdminActor; sessionId: string; requestId: string }) {
    await this.prisma.$transaction(async (tx) => {
      const session = await tx.adminSession.update({ where: { id: input.sessionId }, data: { revokedAt: new Date() }, include: { adminUser: true } });
      await this.adminAudit(tx, input.actor, "admin_session_revoked", "admin_session", session.id, "success", input.requestId, {
        adminUserId: session.adminUserId,
        email: session.adminUser.email
      });
    });
  }

  async exportLicensesCsv(): Promise<string> {
    const licenses = await this.prisma.license.findMany({
      include: { customer: true, activations: { where: { status: "active" } } },
      orderBy: { createdAt: "desc" }
    });
    const header = ["id", "email", "code", "plan", "status", "seatLimit", "activeDevices", "orderProvider", "orderId", "createdAt", "activatedAt", "revokedAt"];
    const rows = licenses.map((license) => [
      license.id,
      license.customer.emailMasked,
      license.codeMasked,
      license.plan,
      license.status,
      license.seatLimit,
      license.activations.length,
      license.orderProvider,
      license.orderId,
      license.createdAt.toISOString(),
      license.activatedAt?.toISOString(),
      license.revokedAt?.toISOString()
    ]);
    return [header.map(csvCell).join(","), ...rows.map((row) => row.map(csvCell).join(","))].join("\n");
  }

  private adminUserDTO(user: AdminUser) {
    return {
      id: user.id,
      email: user.email,
      role: user.role,
      disabledAt: user.disabledAt,
      passwordChangedAt: user.passwordChangedAt,
      createdAt: user.createdAt,
      updatedAt: user.updatedAt
    };
  }

  private adminSessionDTO(session: AdminSession & { adminUser: AdminUser }) {
    return {
      id: session.id,
      adminUserId: session.adminUserId,
      adminEmail: session.adminUser.email,
      expiresAt: session.expiresAt,
      lastSeenAt: session.lastSeenAt,
      revokedAt: session.revokedAt,
      createdAt: session.createdAt,
      status: session.revokedAt ? "revoked" : session.expiresAt <= new Date() ? "expired" : "active"
    };
  }

  private async adminAudit(
    tx: Prisma.TransactionClient,
    actor: AdminActor,
    action: string,
    targetType: string,
    targetId: string,
    result: string,
    requestId: string,
    metadataJson: Prisma.InputJsonValue
  ): Promise<void> {
    await tx.adminAuditLog.create({
      data: {
        adminUserId: actor.id,
        actorSnapshot: actor.email,
        action,
        targetType,
        targetId,
        result,
        requestId,
        metadataJson
      }
    });
  }
}
