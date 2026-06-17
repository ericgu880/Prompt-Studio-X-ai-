import type { PrismaClient } from "@prisma/client";
import { generateLicenseCode, hashLicenseCode, codePrefix, maskLicenseCode } from "../crypto/licenseCode.js";
import { hashEmail, maskEmail, normalizeEmail } from "../crypto/email.js";
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
