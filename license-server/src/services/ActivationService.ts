import type { Activation, Prisma, PrismaClient } from "@prisma/client";
import { randomBytes } from "node:crypto";
import type { AppConfig } from "../config.js";
import { base64urlEncode } from "../crypto/base64url.js";
import { codePrefix, hashLicenseCode } from "../crypto/licenseCode.js";
import { hashEmail, normalizeEmail } from "../crypto/email.js";
import { AuditEventService } from "./AuditEventService.js";
import { CertificateService } from "./CertificateService.js";
import { DeviceProofService } from "./DeviceProofService.js";

export class LicenseAPIError extends Error {
  constructor(
    public readonly code: string,
    public readonly statusCode: number,
    message: string,
    public readonly data?: unknown
  ) {
    super(message);
  }
}

export class ActivationService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
    private readonly audit: AuditEventService,
    private readonly certificates: CertificateService,
    private readonly deviceProof: DeviceProofService
  ) {}

  async activate(input: {
    email: string;
    licenseCode: string;
    installIdHash: string;
    devicePublicKey: string;
    deviceProof: {
      version: string;
      clientNonce: string;
      createdAt: string;
      signature: string;
    };
    deviceLabel: string;
    bundleId: string;
    appVersion?: string;
    osVersion?: string;
  }): Promise<{
    activationId: string;
    licenseCertificate: string;
    refreshAfter: string;
    expiresAt: string;
    graceUntil: string;
    deviceCount: number;
    seatLimit: number;
    serverTime: string;
  }> {
    if (input.deviceProof.version !== "PromptStudio-Activate-Proof-v1") {
      throw new LicenseAPIError("INVALID_ACTIVATE_PROOF", 401, "无法验证当前设备，请重试。");
    }
    const deviceKeyThumbprint = this.deviceProof.deviceKeyThumbprint(input.devicePublicKey);
    const nonceHash = this.deviceProof.nonceHash(input.deviceProof.clientNonce, deviceKeyThumbprint);

    const reusedNonce = await this.prisma.activateProofNonce.findUnique({
      where: { nonceHash_deviceKeyThumbprint: { nonceHash, deviceKeyThumbprint } }
    });
    if (reusedNonce) {
      throw new LicenseAPIError("ACTIVATE_PROOF_REPLAYED", 401, "无法验证当前设备，请重试。");
    }

    try {
      this.deviceProof.verifyActivateProof({
        email: input.email,
        licenseCode: input.licenseCode,
        installIdHash: input.installIdHash,
        devicePublicKey: input.devicePublicKey,
        bundleId: input.bundleId,
        appVersion: input.appVersion,
        osVersion: input.osVersion,
        clientNonce: input.deviceProof.clientNonce,
        createdAt: input.deviceProof.createdAt,
        signature: input.deviceProof.signature
      });
    } catch (error) {
      if (error instanceof Error && error.message === "INVALID_BUNDLE_ID") {
        throw new LicenseAPIError("INVALID_BUNDLE_ID", 403, "当前应用无法使用此授权。");
      }
      throw new LicenseAPIError("INVALID_ACTIVATE_PROOF", 401, "无法验证当前设备，请重试。");
    }

    const normalizedEmail = normalizeEmail(input.email);
    const emailHash = hashEmail(this.config.licenseCodePepper, normalizedEmail);
    const codeHash = hashLicenseCode(this.config.licenseCodePepper, input.licenseCode);
    const displayCodePrefix = codePrefix(input.licenseCode);

    return this.prisma.$transaction(async (tx) => {
      try {
        await tx.activateProofNonce.create({
          data: {
            nonceHash,
            deviceKeyThumbprint,
            expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
            consumedAt: new Date()
          }
        });
      } catch {
        throw new LicenseAPIError("ACTIVATE_PROOF_REPLAYED", 401, "无法验证当前设备，请重试。");
      }

      const license = await tx.license.findUnique({
        where: { codeHash },
        include: { customer: true, activations: { where: { status: "active" } } }
      });
      if (!license || license.customer.emailHash !== emailHash) {
        await tx.licenseEvent.create({
          data: {
            eventType: "activation_failed",
            eventSource: "api",
            emailHash,
            codePrefix: displayCodePrefix
          }
        });
        throw new LicenseAPIError("INVALID_EMAIL_OR_LICENSE", 401, "邮箱或激活码不匹配，请检查购买邮件。");
      }
      if (["refunded", "revoked", "disabled"].includes(license.status)) {
        await tx.licenseEvent.create({
          data: {
            licenseId: license.id,
            eventType: "activation_failed",
            eventSource: "api",
            emailHash,
            codePrefix: license.codePrefix
          }
        });
        throw new LicenseAPIError("LICENSE_NOT_AVAILABLE", 403, "该授权当前不可用，如有疑问请联系支持。");
      }

      const activeForInstall = license.activations.find((activation) => activation.installIdHash === input.installIdHash);
      let activation: Activation;
      if (activeForInstall?.deviceKeyThumbprint === deviceKeyThumbprint) {
        activation = await tx.activation.update({
          where: { id: activeForInstall.id },
          data: {
            lastSeenAt: new Date(),
            appVersion: input.appVersion,
            osVersion: input.osVersion,
            deviceLabel: input.deviceLabel
          }
        });
      } else if (activeForInstall) {
        const replacement = await tx.activation.create({
          data: {
            licenseId: license.id,
            installIdHash: input.installIdHash,
            devicePublicKey: input.devicePublicKey,
            deviceKeyThumbprint,
            deviceLabel: input.deviceLabel,
            appVersion: input.appVersion,
            osVersion: input.osVersion,
            lastSeenAt: new Date()
          }
        });
        await tx.activation.update({
          where: { id: activeForInstall.id },
          data: {
            status: "stale",
            deactivatedAt: new Date(),
            deactivatedReason: "device_key_replaced",
            replacedByActivationId: replacement.id
          }
        });
        activation = replacement;
      } else {
        if (license.activations.length >= license.seatLimit) {
          const devices = license.activations.map((item) => ({
            activationId: item.id,
            deviceLabel: item.deviceLabel,
            activatedAt: item.activatedAt.toISOString(),
            lastSeenAt: item.lastSeenAt?.toISOString() ?? null
          }));
          await tx.licenseEvent.create({
            data: {
              licenseId: license.id,
              eventType: "seat_limit_exceeded",
              eventSource: "api",
              emailHash,
              codePrefix: license.codePrefix
            }
          });
          throw new LicenseAPIError("SEAT_LIMIT_EXCEEDED", 409, "该激活码已达到设备上限。", {
            deviceCount: license.activations.length,
            seatLimit: license.seatLimit,
            devices
          });
        }
        activation = await tx.activation.create({
          data: {
            licenseId: license.id,
            installIdHash: input.installIdHash,
            devicePublicKey: input.devicePublicKey,
            deviceKeyThumbprint,
            deviceLabel: input.deviceLabel,
            appVersion: input.appVersion,
            osVersion: input.osVersion,
            lastSeenAt: new Date()
          }
        });
      }

      const updatedLicense = license.status === "unused"
        ? await tx.license.update({
            where: { id: license.id },
            data: { status: "active", activatedAt: license.activatedAt ?? new Date() }
          })
        : license;

      const issued = await this.certificates.issue({
        license: updatedLicense,
        activation,
        customerEmailHash: emailHash,
        tx
      });

      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          activationId: activation.id,
          eventType: "activation_success",
          eventSource: "api",
          emailHash,
          codePrefix: license.codePrefix
        }
      });

      const deviceCount = await tx.activation.count({ where: { licenseId: license.id, status: "active" } });

      return {
        activationId: activation.id,
        licenseCertificate: issued.certificate,
        refreshAfter: issued.refreshAfter.toISOString(),
        expiresAt: issued.expiresAt.toISOString(),
        graceUntil: issued.graceUntil.toISOString(),
        deviceCount,
        seatLimit: updatedLicense.seatLimit,
        serverTime: issued.issuedAt.toISOString()
      };
    });
  }

  async createRefreshChallenge(activationId: string): Promise<{
    challengeId: string;
    nonce: string;
    expiresAt: string;
  }> {
    const activation = await this.prisma.activation.findUnique({ where: { id: activationId } });
    if (!activation || activation.status !== "active") {
      throw new LicenseAPIError("ACTIVATION_NOT_FOUND", 401, "当前设备授权不存在或已失效。");
    }
    const nonce = base64urlEncode(randomBytes(32));
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000);
    const challenge = await this.prisma.refreshChallenge.create({
      data: { activationId, nonce, expiresAt }
    });
    await this.audit.record({
      licenseId: activation.licenseId,
      activationId,
      eventType: "refresh_challenge_created"
    });
    return { challengeId: challenge.id, nonce, expiresAt: expiresAt.toISOString() };
  }

  async refresh(input: {
    activationId: string;
    challengeId: string;
    signature: string;
    appVersion?: string;
    osVersion?: string;
  }): Promise<{
    licenseCertificate: string;
    refreshAfter: string;
    expiresAt: string;
    graceUntil: string;
    status: string;
    serverTime: string;
  }> {
    return this.withDeviceChallenge(input, "refresh", async (tx, activation) => {
      const license = await tx.license.findUnique({
        where: { id: activation.licenseId },
        include: { customer: true }
      });
      if (!license || ["refunded", "revoked", "disabled"].includes(license.status)) {
        throw new LicenseAPIError("LICENSE_REVOKED", 403, "该授权当前不可用。");
      }
      const updatedActivation = await tx.activation.update({
        where: { id: activation.id },
        data: { lastSeenAt: new Date(), appVersion: input.appVersion, osVersion: input.osVersion }
      });
      const issued = await this.certificates.issue({
        license,
        activation: updatedActivation,
        customerEmailHash: license.customer.emailHash,
        tx
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          activationId: activation.id,
          eventType: "refresh_success",
          eventSource: "api"
        }
      });
      return {
        licenseCertificate: issued.certificate,
        refreshAfter: issued.refreshAfter.toISOString(),
        expiresAt: issued.expiresAt.toISOString(),
        graceUntil: issued.graceUntil.toISOString(),
        status: "active",
        serverTime: issued.issuedAt.toISOString()
      };
    });
  }

  async deactivate(input: {
    activationId: string;
    challengeId: string;
    signature: string;
    reason: string;
  }): Promise<void> {
    await this.withDeviceChallenge(input, "deactivate", async (tx, activation) => {
      await tx.activation.update({
        where: { id: activation.id },
        data: { status: "deactivated", deactivatedAt: new Date(), deactivatedReason: input.reason }
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: activation.licenseId,
          activationId: activation.id,
          eventType: "device_deactivated",
          eventSource: "api",
          metadataJson: { reason: input.reason } as Prisma.InputJsonValue
        }
      });
    });
  }

  async listDevices(input: {
    activationId: string;
    challengeId: string;
    signature: string;
  }): Promise<{
    seatLimit: number;
    activeDeviceCount: number;
    devices: Array<{
      activationId: string;
      label: string;
      status: string;
      platform: string;
      appVersion: string | null;
      osVersion: string | null;
      activatedAt: string;
      lastSeenAt: string | null;
      isCurrent: boolean;
    }>;
  }> {
    return this.withDeviceChallenge(input, "devices_list", async (tx, activation) => {
      const license = await tx.license.findUnique({
        where: { id: activation.licenseId },
        include: {
          activations: {
            where: { status: "active" },
            orderBy: [{ lastSeenAt: "desc" }, { activatedAt: "desc" }]
          }
        }
      });
      if (!license || ["refunded", "revoked", "disabled"].includes(license.status)) {
        throw new LicenseAPIError("LICENSE_REVOKED", 403, "该授权当前不可用。");
      }
      await tx.activation.update({
        where: { id: activation.id },
        data: { lastSeenAt: new Date() }
      });
      return {
        seatLimit: license.seatLimit,
        activeDeviceCount: license.activations.length,
        devices: license.activations.map((device) => ({
          activationId: device.id,
          label: device.deviceLabel,
          status: device.status,
          platform: device.platform,
          appVersion: device.appVersion,
          osVersion: device.osVersion,
          activatedAt: device.activatedAt.toISOString(),
          lastSeenAt: device.lastSeenAt?.toISOString() ?? null,
          isCurrent: device.id === activation.id
        }))
      };
    });
  }

  async renameDevice(input: {
    activationId: string;
    challengeId: string;
    signature: string;
    targetActivationId: string;
    label: string;
  }): Promise<void> {
    await this.withDeviceChallenge(input, "device_rename", async (tx, activation) => {
      const label = input.label.trim();
      const target = await tx.activation.findUnique({ where: { id: input.targetActivationId } });
      if (!target || target.licenseId !== activation.licenseId || target.status !== "active") {
        throw new LicenseAPIError("DEVICE_NOT_FOUND", 404, "设备不存在或已停用。");
      }
      await tx.activation.update({
        where: { id: target.id },
        data: { deviceLabel: label }
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: activation.licenseId,
          activationId: target.id,
          eventType: "device_renamed",
          eventSource: "api",
          metadataJson: { byActivationId: activation.id } as Prisma.InputJsonValue
        }
      });
    });
  }

  async deactivateDeviceById(input: {
    activationId: string;
    challengeId: string;
    signature: string;
    targetActivationId: string;
    reason: string;
  }): Promise<void> {
    await this.withDeviceChallenge(input, "device_deactivate", async (tx, activation) => {
      const target = await tx.activation.findUnique({ where: { id: input.targetActivationId } });
      if (!target || target.licenseId !== activation.licenseId || target.status !== "active") {
        throw new LicenseAPIError("DEVICE_NOT_FOUND", 404, "设备不存在或已停用。");
      }
      await tx.activation.update({
        where: { id: target.id },
        data: { status: "deactivated", deactivatedAt: new Date(), deactivatedReason: input.reason }
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: activation.licenseId,
          activationId: target.id,
          eventType: "device_deactivated",
          eventSource: "api",
          metadataJson: { reason: input.reason, byActivationId: activation.id } as Prisma.InputJsonValue
        }
      });
    });
  }

  async recover(email: string): Promise<void> {
    const emailHash = hashEmail(this.config.licenseCodePepper, normalizeEmail(email));
    await this.audit.record({ eventType: "license_recover_requested", emailHash });
  }

  private async withDeviceChallenge<T>(
    input: { activationId: string; challengeId: string; signature: string },
    purpose: "refresh" | "deactivate" | "devices_list" | "device_rename" | "device_deactivate",
    work: (tx: Prisma.TransactionClient, activation: Activation) => Promise<T>
  ): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      const challenge = await tx.refreshChallenge.findUnique({
        where: { id: input.challengeId },
        include: { activation: true }
      });
      if (!challenge || challenge.activationId !== input.activationId || challenge.consumedAt || challenge.expiresAt < new Date()) {
        throw new LicenseAPIError("INVALID_CHALLENGE", 401, "授权验证已过期，请重试。");
      }
      const activation = challenge.activation;
      if (activation.status !== "active") {
        throw new LicenseAPIError("ACTIVATION_NOT_FOUND", 401, "当前设备授权不存在或已失效。");
      }
      try {
        this.deviceProof.verifyDeviceProof({
          activationId: input.activationId,
          challengeId: input.challengeId,
          nonce: challenge.nonce,
          bundleId: this.config.bundleId,
          signature: input.signature,
          devicePublicKey: activation.devicePublicKey
        });
      } catch {
        await tx.licenseEvent.create({
          data: {
            licenseId: activation.licenseId,
            activationId: activation.id,
            eventType: `${purpose}_failed`,
            eventSource: "api",
            metadataJson: { reason: "invalid_device_proof" }
          }
        });
        throw new LicenseAPIError("INVALID_DEVICE_PROOF", 401, "无法验证当前设备授权。");
      }
      const consumed = await tx.refreshChallenge.updateMany({
        where: { id: challenge.id, consumedAt: null },
        data: { consumedAt: new Date() }
      });
      if (consumed.count !== 1) {
        throw new LicenseAPIError("CHALLENGE_REPLAYED", 401, "授权验证已过期，请重试。");
      }
      return work(tx, activation);
    });
  }
}
