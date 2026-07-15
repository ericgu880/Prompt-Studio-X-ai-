import { Prisma, type PrismaClient } from "@prisma/client";
import { generateLicenseCode, hashLicenseCode, codePrefix, maskLicenseCode } from "../crypto/licenseCode.js";
import { hashEmail, maskEmail, normalizeEmail } from "../crypto/email.js";
import { SecretBox } from "../crypto/secretBox.js";
import type { AppConfig } from "../config.js";
import { AuditEventService } from "./AuditEventService.js";

export class LicenseService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
    private readonly audit: AuditEventService
  ) {}

  async createLicense(input: {
    email: string;
    plan: string;
    seats: number;
    orderProvider?: string;
    orderId?: string;
  }): Promise<{
    id: string;
    emailMasked: string;
    plan: string;
    seats: number;
    licenseCode: string;
  }> {
    const normalizedEmail = normalizeEmail(input.email);
    const emailHash = hashEmail(this.config.licenseCodePepper, normalizedEmail);
    const emailMasked = maskEmail(normalizedEmail);
    const licenseCode = generateLicenseCode();
    const codeHash = hashLicenseCode(this.config.licenseCodePepper, licenseCode);

    const customer = await this.prisma.customer.upsert({
      where: { emailHash },
      create: { emailHash, emailMasked },
      update: { emailMasked }
    });

    const license = await this.prisma.license.create({
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

    await this.audit.record({
      licenseId: license.id,
      eventType: "license_created",
      eventSource: "cli",
      emailHash,
      codePrefix: license.codePrefix,
      metadataJson: { seats: input.seats, plan: input.plan }
    });

    return {
      id: license.id,
      emailMasked,
      plan: license.plan,
      seats: license.seatLimit,
      licenseCode
    };
  }

  async provisionLifetimeLicense(input: {
    email: string;
    orderProvider: string;
    orderId: string;
    plan: "pro_lifetime";
    seats: number;
    majorVersion: number;
    purchasedAt: Date;
    updatesDays: number;
  }): Promise<{ created: boolean; licenseId: string }> {
    const normalizedEmail = normalizeEmail(input.email);
    const emailHash = hashEmail(this.config.licenseCodePepper, normalizedEmail);
    const emailMasked = maskEmail(normalizedEmail);
    const updatesUntil = new Date(input.purchasedAt.getTime() + input.updatesDays * 24 * 60 * 60 * 1_000);
    const secretBox = new SecretBox(this.config.commercial.dataEncryptionKeyB64);

    try {
      return await this.prisma.$transaction(async (tx) => {
        const observedAt = new Date();
        const orderState = await tx.commerceOrderState.upsert({
          where: {
            provider_orderId: {
              provider: input.orderProvider,
              orderId: input.orderId,
            },
          },
          create: {
            provider: input.orderProvider,
            orderId: input.orderId,
            lastObservedAt: observedAt,
          },
          update: { lastObservedAt: observedAt },
        });
        const existing = await tx.license.findUnique({
          where: {
            orderProvider_orderId: {
              orderProvider: input.orderProvider,
              orderId: input.orderId,
            },
          },
          select: { id: true },
        });
        if (existing) return { created: false, licenseId: existing.id };

        const licenseCode = generateLicenseCode();
        const customer = await tx.customer.upsert({
          where: { emailHash },
          create: {
            emailHash,
            emailMasked,
            emailEncrypted: secretBox.seal(normalizedEmail),
            emailEncryptionVersion: 1,
          },
          update: {
            emailMasked,
            emailEncrypted: secretBox.seal(normalizedEmail),
            emailEncryptionVersion: 1,
          },
        });
        const license = await tx.license.create({
          data: {
            customerId: customer.id,
            codePrefix: codePrefix(licenseCode),
            codeHash: hashLicenseCode(this.config.licenseCodePepper, licenseCode),
            codeMasked: maskLicenseCode(licenseCode),
            plan: input.plan,
            licenseType: "lifetime",
            seatLimit: input.seats,
            majorVersion: input.majorVersion,
            updatesUntil,
            orderProvider: input.orderProvider,
            orderId: input.orderId,
            createdAt: input.purchasedAt,
            status: orderState.fullRefund ? "refunded" : "unused",
            refundedAt: orderState.fullRefund ? orderState.refundedAt : null,
          },
        });
        if (!orderState.fullRefund) {
          await tx.emailOutbox.create({
            data: {
              kind: "purchase",
              licenseId: license.id,
              recipientHash: emailHash,
              idempotencyKey: `purchase:${input.orderProvider}:${input.orderId}`,
              payloadEncrypted: secretBox.seal(JSON.stringify({
                version: 1,
                kind: "purchase",
                to: normalizedEmail,
                emailMasked,
                licenseCode,
                plan: input.plan,
                seats: input.seats,
                majorVersion: input.majorVersion,
                updatesUntil: updatesUntil.toISOString(),
              })),
            },
          });
        }
        await tx.licenseEvent.create({
          data: {
            licenseId: license.id,
            eventType: "license_created",
            eventSource: "system",
            emailHash,
            codePrefix: license.codePrefix,
            metadataJson: {
              plan: input.plan,
              seats: input.seats,
              orderProvider: input.orderProvider,
              updatesUntil: updatesUntil.toISOString(),
            },
          },
        });
        if (orderState.refundedAmount > 0 || orderState.fullRefund) {
          await tx.licenseEvent.create({
            data: {
              licenseId: license.id,
              eventType: orderState.fullRefund ? "license_refunded" : "license_partial_refund",
              eventSource: "system",
              codePrefix: license.codePrefix,
              metadataJson: {
                orderProvider: input.orderProvider,
                refundedAmount: orderState.refundedAmount,
                orderTotal: orderState.orderTotal,
                reconciledAfterOrder: true,
              },
            },
          });
          await tx.commerceOrderState.update({
            where: { id: orderState.id },
            data: { appliedAt: observedAt },
          });
        }
        return { created: true, licenseId: license.id };
      });
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === "P2002") {
        const existing = await this.prisma.license.findUnique({
          where: {
            orderProvider_orderId: {
              orderProvider: input.orderProvider,
              orderId: input.orderId,
            },
          },
          select: { id: true },
        });
        if (existing) return { created: false, licenseId: existing.id };
      }
      throw error;
    }
  }

  async applyCommerceRefund(input: {
    orderProvider: string;
    orderId: string;
    fullRefund: boolean;
    refundedAt: Date;
    refundedAmount: number;
    orderTotal: number;
  }): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const observedAt = new Date();
      const priorState = await tx.commerceOrderState.upsert({
        where: {
          provider_orderId: {
            provider: input.orderProvider,
            orderId: input.orderId,
          },
        },
        create: {
          provider: input.orderProvider,
          orderId: input.orderId,
          fullRefund: input.fullRefund,
          refundedAmount: input.refundedAmount,
          orderTotal: input.orderTotal,
          refundedAt: input.refundedAt,
          lastObservedAt: observedAt,
        },
        update: { lastObservedAt: observedAt },
      });
      const refundedAt = priorState.refundedAt && priorState.refundedAt > input.refundedAt
        ? priorState.refundedAt
        : input.refundedAt;
      const orderState = await tx.commerceOrderState.update({
        where: { id: priorState.id },
        data: {
          fullRefund: priorState.fullRefund || input.fullRefund,
          refundedAmount: Math.max(priorState.refundedAmount, input.refundedAmount),
          orderTotal: Math.max(priorState.orderTotal, input.orderTotal),
          refundedAt,
        },
      });
      const license = await tx.license.findUnique({
        where: {
          orderProvider_orderId: {
            orderProvider: input.orderProvider,
            orderId: input.orderId,
          },
        },
      });
      if (!license) return;

      if (orderState.fullRefund && license.status !== "refunded") {
        await tx.license.update({
          where: { id: license.id },
          data: {
            status: "refunded",
            refundedAt: input.refundedAt,
            version: { increment: 1 },
          },
        });
      }
      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          eventType: input.fullRefund ? "license_refunded" : "license_partial_refund",
          eventSource: "system",
          codePrefix: license.codePrefix,
          metadataJson: {
            orderProvider: input.orderProvider,
            refundedAmount: input.refundedAmount,
            orderTotal: input.orderTotal,
          },
        },
      });
      await tx.commerceOrderState.update({
        where: { id: orderState.id },
        data: { appliedAt: observedAt },
      });
    });
  }

  async listLicenses(email?: string): Promise<Array<{
    id: string;
    email: string;
    code: string;
    plan: string;
    status: string;
    seats: number;
    activeDevices: number;
    createdAt: Date;
  }>> {
    const where = email
      ? { customer: { emailHash: hashEmail(this.config.licenseCodePepper, normalizeEmail(email)) } }
      : {};
    const licenses = await this.prisma.license.findMany({
      where,
      include: { customer: true, activations: true },
      orderBy: { createdAt: "desc" }
    });
    return licenses.map((license) => ({
      id: license.id,
      email: license.customer.emailMasked,
      code: license.codeMasked,
      plan: license.plan,
      status: license.status,
      seats: license.seatLimit,
      activeDevices: license.activations.filter((activation) => activation.status === "active").length,
      createdAt: license.createdAt
    }));
  }

  async getLicenseDetail(licenseId: string): Promise<{
    id: string;
    email: string;
    code: string;
    codePrefix: string;
    plan: string;
    type: string;
    status: string;
    seats: number;
    majorVersion: number;
    updatesUntil: Date | null;
    orderProvider: string | null;
    orderId: string | null;
    createdAt: Date;
    activatedAt: Date | null;
    revokedAt: Date | null;
    revokedReason: string | null;
    devices: Array<{
      id: string;
      label: string;
      status: string;
      platform: string;
      appVersion: string | null;
      osVersion: string | null;
      activatedAt: Date;
      lastSeenAt: Date | null;
      deactivatedAt: Date | null;
      deactivatedReason: string | null;
    }>;
    events: Array<{
      id: string;
      eventType: string;
      eventSource: string;
      activationId: string | null;
      createdAt: Date;
    }>;
  } | null> {
    const license = await this.prisma.license.findUnique({
      where: { id: licenseId },
      include: {
        customer: true,
        activations: { orderBy: { activatedAt: "desc" } },
        events: { orderBy: { createdAt: "desc" }, take: 30 }
      }
    });
    if (!license) return null;
    return {
      id: license.id,
      email: license.customer.emailMasked,
      code: license.codeMasked,
      codePrefix: license.codePrefix,
      plan: license.plan,
      type: license.licenseType,
      status: license.status,
      seats: license.seatLimit,
      majorVersion: license.majorVersion,
      updatesUntil: license.updatesUntil,
      orderProvider: license.orderProvider,
      orderId: license.orderId,
      createdAt: license.createdAt,
      activatedAt: license.activatedAt,
      revokedAt: license.revokedAt,
      revokedReason: license.revokedReason,
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
      }))
    };
  }

  async addSeats(licenseId: string, seats: number): Promise<void> {
    const license = await this.prisma.license.update({
      where: { id: licenseId },
      data: { seatLimit: { increment: seats } }
    });
    await this.audit.record({
      licenseId,
      eventType: "license_seats_added",
      eventSource: "cli",
      metadataJson: { seats, seatLimit: license.seatLimit }
    });
  }

  async revokeLicense(licenseId: string, reason: string): Promise<void> {
    await this.prisma.license.update({
      where: { id: licenseId },
      data: { status: "revoked", revokedAt: new Date(), revokedReason: reason }
    });
    await this.audit.record({
      licenseId,
      eventType: "license_revoked",
      eventSource: "cli",
      metadataJson: { reason }
    });
  }

  async deactivateDevice(activationId: string, reason: string): Promise<void> {
    const activation = await this.prisma.activation.update({
      where: { id: activationId },
      data: { status: "deactivated", deactivatedAt: new Date(), deactivatedReason: reason }
    });
    await this.audit.record({
      licenseId: activation.licenseId,
      activationId,
      eventType: "device_deactivated",
      eventSource: "cli",
      metadataJson: { reason }
    });
  }

  async rotateCode(licenseId: string, reason: string): Promise<string> {
    const licenseCode = generateLicenseCode();
    const updated = await this.prisma.license.update({
      where: { id: licenseId },
      data: {
        codePrefix: codePrefix(licenseCode),
        codeHash: hashLicenseCode(this.config.licenseCodePepper, licenseCode),
        codeMasked: maskLicenseCode(licenseCode)
      }
    });
    await this.audit.record({
      licenseId,
      eventType: "license_code_rotated",
      eventSource: "cli",
      codePrefix: updated.codePrefix,
      metadataJson: { reason }
    });
    return licenseCode;
  }
}
