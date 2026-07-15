import type { Prisma, PrismaClient } from "@prisma/client";
import type { AppConfig } from "../config.js";
import { hashEmail, maskEmail, normalizeEmail } from "../crypto/email.js";
import { codePrefix, generateLicenseCode, hashLicenseCode, maskLicenseCode } from "../crypto/licenseCode.js";
import { AdminAPIError } from "./AdminAuthService.js";

export interface AdminActor {
  id: string;
  email: string;
}

export class AdminLicenseService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig
  ) {}

  async listLicenses(input: {
    page: number;
    pageSize: number;
    email?: string;
    status?: string;
    plan?: string;
    orderProvider?: string;
  }): Promise<{
    items: Array<{
      id: string;
      email: string;
      code: string;
      plan: string;
      status: string;
      seats: number;
      activeDevices: number;
      version: number;
      orderProvider: string | null;
      orderId: string | null;
      createdAt: Date;
      activatedAt: Date | null;
    }>;
    page: number;
    pageSize: number;
    total: number;
  }> {
    const where: Prisma.LicenseWhereInput = {
      ...(input.email ? { customer: { emailHash: hashEmail(this.config.licenseCodePepper, normalizeEmail(input.email)) } } : {}),
      ...(input.status ? { status: input.status as Prisma.EnumLicenseStatusFilter<"License"> } : {}),
      ...(input.plan ? { plan: input.plan } : {}),
      ...(input.orderProvider ? { orderProvider: input.orderProvider.trim().toLowerCase() } : {})
    };
    const [total, licenses] = await this.prisma.$transaction([
      this.prisma.license.count({ where }),
      this.prisma.license.findMany({
        where,
        include: { customer: true, activations: true },
        orderBy: { createdAt: "desc" },
        skip: (input.page - 1) * input.pageSize,
        take: input.pageSize
      })
    ]);
    return {
      page: input.page,
      pageSize: input.pageSize,
      total,
      items: licenses.map((license) => ({
        id: license.id,
        email: license.customer.emailMasked,
        code: license.codeMasked,
        plan: license.plan,
        status: license.status,
        seats: license.seatLimit,
        activeDevices: license.activations.filter((activation) => activation.status === "active").length,
        version: license.version,
        orderProvider: license.orderProvider,
        orderId: license.orderId,
        createdAt: license.createdAt,
        activatedAt: license.activatedAt
      }))
    };
  }

  async getLicenseDetail(licenseId: string): Promise<unknown> {
    const [license, auditLogs] = await this.prisma.$transaction([
      this.prisma.license.findUnique({
        where: { id: licenseId },
        include: {
          customer: true,
          activations: { orderBy: { activatedAt: "desc" } },
          events: { orderBy: { createdAt: "desc" }, take: 30 }
        }
      }),
      this.prisma.adminAuditLog.findMany({
        where: { targetType: "license", targetId: licenseId },
        orderBy: { createdAt: "desc" },
        take: 30
      })
    ]);
    if (!license) return null;
    return {
      id: license.id,
      email: license.customer.emailMasked,
      code: license.codeMasked,
      plan: license.plan,
      type: license.licenseType,
      status: license.status,
      seats: license.seatLimit,
      version: license.version,
      activeDevices: license.activations.filter((activation) => activation.status === "active").length,
      createdAt: license.createdAt,
      activatedAt: license.activatedAt,
      revokedAt: license.revokedAt,
      revokedReason: license.revokedReason,
      orderProvider: license.orderProvider,
      orderId: license.orderId,
      devices: license.activations.map((activation) => ({
        id: activation.id,
        label: activation.deviceLabel,
        status: activation.status,
        platform: activation.platform,
        appVersion: activation.appVersion,
        osVersion: activation.osVersion,
        activatedAt: activation.activatedAt,
        lastSeenAt: activation.lastSeenAt,
        deactivatedAt: activation.deactivatedAt,
        deactivatedReason: activation.deactivatedReason
      })),
      events: license.events.map((event) => ({
        id: event.id,
        eventType: event.eventType,
        eventSource: event.eventSource,
        activationId: event.activationId,
        createdAt: event.createdAt
      })),
      auditLogs: auditLogs.map((log) => ({
        id: log.id,
        adminUserId: log.adminUserId,
        actorSnapshot: log.actorSnapshot,
        action: log.action,
        result: log.result,
        requestId: log.requestId,
        createdAt: log.createdAt
      }))
    };
  }

  async createLicense(input: {
    actor: AdminActor;
    email: string;
    plan: string;
    seats: number;
    idempotencyKey: string;
    requestHash: string;
    requestId: string;
    ipHmac?: string;
    userAgentHmac?: string;
    orderProvider?: string;
    orderId?: string;
  }): Promise<
    | { created: true; id: string; emailMasked: string; plan: string; seats: number; licenseCode: string }
    | { created: false; existingLicenseId: string; recoveryRequired: true }
  > {
    return this.prisma.$transaction(async (tx) => {
      const existingIdempotency = await tx.adminIdempotencyRecord.findUnique({
        where: {
          adminUserId_route_key: {
            adminUserId: input.actor.id,
            route: "POST /admin-api/licenses",
            key: input.idempotencyKey
          }
        }
      });
      if (existingIdempotency) {
        if (existingIdempotency.requestHash !== input.requestHash) {
          throw new AdminAPIError("IDEMPOTENCY_KEY_REUSED", 409, "Idempotency-Key 已被不同请求使用。");
        }
        return { created: false, existingLicenseId: existingIdempotency.resourceId ?? "", recoveryRequired: true };
      }

      if (input.orderProvider && input.orderId) {
        const existingOrder = await tx.license.findFirst({
          where: { orderProvider: input.orderProvider, orderId: input.orderId }
        });
        if (existingOrder) {
          await tx.adminIdempotencyRecord.create({
            data: {
              adminUserId: input.actor.id,
              route: "POST /admin-api/licenses",
              key: input.idempotencyKey,
              requestHash: input.requestHash,
              resourceId: existingOrder.id,
              expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000)
            }
          });
          throw new AdminAPIError("ORDER_ALREADY_EXISTS", 409, "订单已创建授权，请进入详情后轮换激活码。", {
            existingLicenseId: existingOrder.id
          });
        }
      }

      const normalizedEmail = normalizeEmail(input.email);
      const emailHash = hashEmail(this.config.licenseCodePepper, normalizedEmail);
      const emailMasked = maskEmail(normalizedEmail);
      const licenseCode = generateLicenseCode();
      const codeHash = hashLicenseCode(this.config.licenseCodePepper, licenseCode);
      const customer = await tx.customer.upsert({
        where: { emailHash },
        create: { emailHash, emailMasked },
        update: { emailMasked }
      });
      const license = await tx.license.create({
        data: {
          customerId: customer.id,
          codePrefix: codePrefix(licenseCode),
          codeHash,
          codeMasked: maskLicenseCode(licenseCode),
          plan: input.plan,
          seatLimit: input.seats,
          orderProvider: input.orderProvider,
          orderId: input.orderId
        }
      });
      await tx.adminIdempotencyRecord.create({
        data: {
          adminUserId: input.actor.id,
          route: "POST /admin-api/licenses",
          key: input.idempotencyKey,
          requestHash: input.requestHash,
          resourceId: license.id,
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000)
        }
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          eventType: "license_created",
          eventSource: "system",
          emailHash,
          codePrefix: license.codePrefix,
          metadataJson: { seats: input.seats, plan: input.plan, adminUserId: input.actor.id } as Prisma.InputJsonValue
        }
      });
      await tx.adminAuditLog.create({
        data: {
          adminUserId: input.actor.id,
          actorSnapshot: input.actor.email,
          action: "license_created",
          targetType: "license",
          targetId: license.id,
          result: "success",
          requestId: input.requestId,
          ipHmac: input.ipHmac,
          userAgentHmac: input.userAgentHmac,
          metadataJson: { plan: input.plan, seats: input.seats, emailMasked } as Prisma.InputJsonValue
        }
      });
      return { created: true, id: license.id, emailMasked, plan: license.plan, seats: license.seatLimit, licenseCode };
    });
  }

  async setSeatLimit(input: { actor: AdminActor; licenseId: string; seatLimit: number; expectedVersion: number; reason: string; requestId: string }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const activeCount = await tx.activation.count({ where: { licenseId: input.licenseId, status: "active" } });
      if (input.seatLimit < activeCount) {
        throw new AdminAPIError("SEAT_LIMIT_BELOW_ACTIVE_DEVICES", 400, "席位数不能小于有效激活设备数。");
      }
      const updated = await tx.license.updateMany({
        where: { id: input.licenseId, version: input.expectedVersion },
        data: { seatLimit: input.seatLimit, version: { increment: 1 } }
      });
      if (updated.count !== 1) {
        throw new AdminAPIError("LICENSE_VERSION_CONFLICT", 409, "授权已被更新，请刷新后重试。");
      }
      await tx.licenseEvent.create({
        data: {
          licenseId: input.licenseId,
          eventType: "license_seat_limit_updated",
          eventSource: "system",
          metadataJson: { seatLimit: input.seatLimit, reason: input.reason, adminUserId: input.actor.id } as Prisma.InputJsonValue
        }
      });
      await this.adminAudit(tx, input.actor, "license_seat_limit_updated", input.licenseId, "success", input.requestId, {
        seatLimit: input.seatLimit,
        reason: input.reason
      });
    });
  }

  async revokeLicense(input: { actor: AdminActor; licenseId: string; expectedVersion: number; reason: string; requestId: string }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const updated = await tx.license.updateMany({
        where: { id: input.licenseId, version: input.expectedVersion, status: { not: "revoked" } },
        data: { status: "revoked", revokedAt: new Date(), revokedReason: input.reason, version: { increment: 1 } }
      });
      if (updated.count !== 1) {
        throw new AdminAPIError("LICENSE_VERSION_CONFLICT", 409, "授权已被更新，请刷新后重试。");
      }
      await tx.licenseEvent.create({
        data: {
          licenseId: input.licenseId,
          eventType: "license_revoked",
          eventSource: "system",
          metadataJson: { reason: input.reason, adminUserId: input.actor.id } as Prisma.InputJsonValue
        }
      });
      await this.adminAudit(tx, input.actor, "license_revoked", input.licenseId, "success", input.requestId, { reason: input.reason });
    });
  }

  async rotateCode(input: { actor: AdminActor; licenseId: string; expectedVersion: number; reason: string; requestId: string }): Promise<string> {
    return this.prisma.$transaction(async (tx) => {
      const licenseCode = generateLicenseCode();
      const updated = await tx.license.updateMany({
        where: { id: input.licenseId, version: input.expectedVersion },
        data: {
          codePrefix: codePrefix(licenseCode),
          codeHash: hashLicenseCode(this.config.licenseCodePepper, licenseCode),
          codeMasked: maskLicenseCode(licenseCode),
          version: { increment: 1 }
        }
      });
      if (updated.count !== 1) {
        throw new AdminAPIError("LICENSE_VERSION_CONFLICT", 409, "授权已被更新，请刷新后重试。");
      }
      await tx.licenseEvent.create({
        data: {
          licenseId: input.licenseId,
          eventType: "license_code_rotated",
          eventSource: "system",
          codePrefix: codePrefix(licenseCode),
          metadataJson: { reason: input.reason, adminUserId: input.actor.id } as Prisma.InputJsonValue
        }
      });
      await this.adminAudit(tx, input.actor, "license_code_rotated", input.licenseId, "success", input.requestId, { reason: input.reason });
      return licenseCode;
    });
  }

  async deactivateDevice(input: { actor: AdminActor; activationId: string; reason: string; requestId: string }): Promise<{ status: string }> {
    return this.prisma.$transaction(async (tx) => {
      const activation = await tx.activation.findUnique({ where: { id: input.activationId } });
      if (!activation) {
        throw new AdminAPIError("DEVICE_NOT_FOUND", 404, "设备不存在。");
      }
      if (activation.status !== "active") {
        await this.adminAudit(tx, input.actor, "device_deactivated", activation.licenseId, "noop", input.requestId, {
          activationId: activation.id,
          reason: input.reason
        });
        return { status: activation.status };
      }
      await tx.activation.update({
        where: { id: activation.id },
        data: { status: "deactivated", deactivatedAt: new Date(), deactivatedReason: input.reason }
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: activation.licenseId,
          activationId: activation.id,
          eventType: "device_deactivated",
          eventSource: "system",
          metadataJson: { reason: input.reason, adminUserId: input.actor.id } as Prisma.InputJsonValue
        }
      });
      await this.adminAudit(tx, input.actor, "device_deactivated", activation.licenseId, "success", input.requestId, {
        activationId: activation.id,
        reason: input.reason
      });
      return { status: "deactivated" };
    });
  }

  private async adminAudit(
    tx: Prisma.TransactionClient,
    actor: AdminActor,
    action: string,
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
        targetType: "license",
        targetId,
        result,
        requestId,
        metadataJson
      }
    });
  }
}
