import type { Activation, Prisma, PrismaClient } from "@prisma/client";
import { randomBytes, randomUUID } from "node:crypto";
import type { AppConfig } from "../config.js";
import { base64urlEncode } from "../crypto/base64url.js";
import { codePrefix, hashLicenseCode } from "../crypto/licenseCode.js";
import { hashEmail, normalizeEmail } from "../crypto/email.js";
import { AuditEventService } from "./AuditEventService.js";
import { CertificateService } from "./CertificateService.js";
import { DeviceProofService } from "./DeviceProofService.js";
import { RecoveryService } from "./RecoveryService.js";

type AuthorizedLicense = Prisma.LicenseGetPayload<{
  include: { customer: true; activations: true };
}>;

interface ActivationDeviceInput {
  installIdHash: string;
  devicePublicKey: string;
  deviceLabel: string;
  bundleId: string;
  appVersion?: string;
  osVersion?: string;
  replaceActivationId?: string;
}

interface ActivationResult {
  activationId: string;
  licenseCertificate: string;
  refreshAfter: string;
  expiresAt: string;
  graceUntil: string;
  deviceCount: number;
  seatLimit: number;
  serverTime: string;
}

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
    private readonly deviceProof: DeviceProofService,
    private readonly recovery: RecoveryService
  ) {}

  async activate(input: ActivationDeviceInput & {
    email: string;
    licenseCode: string;
    deviceProof: {
      version: string;
      clientNonce: string;
      createdAt: string;
      signature: string;
    };
  }): Promise<ActivationResult> {
    if (input.deviceProof.version !== "PromptStudio-Activate-Proof-v1") {
      throw new LicenseAPIError("INVALID_ACTIVATE_PROOF", 401, "无法验证当前设备，请重试。");
    }
    const deviceKeyThumbprint = this.deviceProof.deviceKeyThumbprint(input.devicePublicKey);
    const nonceHash = this.deviceProof.nonceHash(input.deviceProof.clientNonce, deviceKeyThumbprint);
    await this.rejectReplayedProof(nonceHash, deviceKeyThumbprint);
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
      await this.consumeProofNonce(tx, nonceHash, deviceKeyThumbprint);
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
      return this.activateAuthorized(tx, license, emailHash, input, deviceKeyThumbprint, "license_code");
    }, { isolationLevel: "Serializable" });
  }

  async activateWithRecovery(input: ActivationDeviceInput & {
    recoveryToken: string;
    deviceProof: {
      version: string;
      clientNonce: string;
      createdAt: string;
      signature: string;
    };
  }): Promise<ActivationResult> {
    if (input.deviceProof.version !== "PromptStudio-Recovery-Proof-v1") {
      throw new LicenseAPIError("INVALID_RECOVERY_PROOF", 401, "无法验证当前设备，请重新打开找回邮件。");
    }
    const deviceKeyThumbprint = this.deviceProof.deviceKeyThumbprint(input.devicePublicKey);
    const nonceHash = this.deviceProof.nonceHash(input.deviceProof.clientNonce, deviceKeyThumbprint);
    await this.rejectReplayedProof(nonceHash, deviceKeyThumbprint);
    try {
      this.deviceProof.verifyRecoveryProof({
        recoveryToken: input.recoveryToken,
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
      throw new LicenseAPIError("INVALID_RECOVERY_PROOF", 401, "无法验证当前设备，请重新打开找回邮件。");
    }

    return this.prisma.$transaction(async (tx) => {
      await this.consumeProofNonce(tx, nonceHash, deviceKeyThumbprint);
      const token = await tx.licenseRecoveryToken.findUnique({
        where: { tokenHash: this.recovery.hashToken(input.recoveryToken) },
        include: {
          license: {
            include: { customer: true, activations: { where: { status: "active" } } }
          }
        }
      });
      if (!token || token.consumedAt) {
        throw new LicenseAPIError("RECOVERY_TOKEN_INVALID", 401, "找回链接无效，请重新发送邮件。");
      }
      if (token.expiresAt <= new Date()) {
        throw new LicenseAPIError("RECOVERY_TOKEN_EXPIRED", 401, "找回链接已过期，请重新发送邮件。");
      }
      if (["refunded", "revoked", "disabled"].includes(token.license.status)) {
        throw new LicenseAPIError("LICENSE_NOT_AVAILABLE", 403, "该授权当前不可用，如有疑问请联系支持。");
      }

      const result = await this.activateAuthorized(
        tx,
        token.license,
        token.requestEmailHash,
        input,
        deviceKeyThumbprint,
        "recovery",
      );
      const consumed = await tx.licenseRecoveryToken.updateMany({
        where: { id: token.id, consumedAt: null },
        data: { consumedAt: new Date() }
      });
      if (consumed.count !== 1) {
        throw new LicenseAPIError("RECOVERY_TOKEN_INVALID", 401, "找回链接无效，请重新发送邮件。");
      }
      return result;
    }, { isolationLevel: "Serializable" });
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

  private async activateAuthorized(
    tx: Prisma.TransactionClient,
    license: AuthorizedLicense,
    emailHash: string,
    input: ActivationDeviceInput,
    deviceKeyThumbprint: string,
    credentialSource: "license_code" | "recovery",
  ): Promise<ActivationResult> {
    const now = new Date();
    const activeForInstall = license.activations.find((item) => item.installIdHash === input.installIdHash);
    let activation: Activation;
    let replacedActivationId: string | undefined;

    if (activeForInstall?.deviceKeyThumbprint === deviceKeyThumbprint) {
      activation = await tx.activation.update({
        where: { id: activeForInstall.id },
        data: {
          lastSeenAt: now,
          appVersion: input.appVersion,
          osVersion: input.osVersion,
          deviceLabel: input.deviceLabel,
        },
      });
    } else if (activeForInstall) {
      const replacementId = randomUUID();
      await tx.activation.update({
        where: { id: activeForInstall.id },
        data: {
          status: "stale",
          deactivatedAt: now,
          deactivatedReason: "device_key_replaced",
          replacedByActivationId: replacementId,
        },
      });
      activation = await tx.activation.create({
        data: this.activationData(replacementId, license.id, input, deviceKeyThumbprint, now),
      });
      replacedActivationId = activeForInstall.id;
    } else if (input.replaceActivationId) {
      const target = license.activations.find((item) => item.id === input.replaceActivationId);
      if (!target) {
        throw new LicenseAPIError("DEVICE_NOT_REPLACEABLE", 409, "所选设备已停用，请刷新设备列表后重试。");
      }
      const replacementId = randomUUID();
      await tx.activation.update({
        where: { id: target.id },
        data: {
          status: "deactivated",
          deactivatedAt: now,
          deactivatedReason: "seat_replaced",
          replacedByActivationId: replacementId,
        },
      });
      activation = await tx.activation.create({
        data: this.activationData(replacementId, license.id, input, deviceKeyThumbprint, now),
      });
      replacedActivationId = target.id;
      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          activationId: target.id,
          eventType: "device_replaced",
          eventSource: "api",
          metadataJson: { replacementActivationId: replacementId },
        },
      });
    } else {
      if (license.activations.length >= license.seatLimit) {
        throw new LicenseAPIError("SEAT_LIMIT_EXCEEDED", 409, "该激活码已达到设备上限。", {
          deviceCount: license.activations.length,
          seatLimit: license.seatLimit,
          devices: license.activations.map((item) => ({
            activationId: item.id,
            deviceLabel: item.deviceLabel,
            platform: item.platform,
            appVersion: item.appVersion,
            activatedAt: item.activatedAt.toISOString(),
            lastSeenAt: item.lastSeenAt?.toISOString() ?? null,
          })),
        });
      }
      activation = await tx.activation.create({
        data: this.activationData(randomUUID(), license.id, input, deviceKeyThumbprint, now),
      });
    }

    const updatedLicense = license.status === "unused"
      ? await tx.license.update({
          where: { id: license.id },
          data: { status: "active", activatedAt: license.activatedAt ?? now },
        })
      : license;
    const issued = await this.certificates.issue({
      license: updatedLicense,
      activation,
      customerEmailHash: emailHash,
      tx,
    });
    await tx.licenseEvent.create({
      data: {
        licenseId: license.id,
        activationId: activation.id,
        eventType: "activation_success",
        eventSource: "api",
        emailHash,
        codePrefix: license.codePrefix,
        metadataJson: {
          credentialSource,
          ...(replacedActivationId ? { replacedActivationId } : {}),
        },
      },
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
      serverTime: issued.issuedAt.toISOString(),
    };
  }

  private activationData(
    id: string,
    licenseId: string,
    input: ActivationDeviceInput,
    deviceKeyThumbprint: string,
    now: Date,
  ): Prisma.ActivationUncheckedCreateInput {
    return {
      id,
      licenseId,
      installIdHash: input.installIdHash,
      devicePublicKey: input.devicePublicKey,
      deviceKeyThumbprint,
      deviceLabel: input.deviceLabel,
      platform: "macos",
      appVersion: input.appVersion,
      osVersion: input.osVersion,
      lastSeenAt: now,
    };
  }

  private async rejectReplayedProof(nonceHash: string, deviceKeyThumbprint: string): Promise<void> {
    const reusedNonce = await this.prisma.activateProofNonce.findUnique({
      where: { nonceHash_deviceKeyThumbprint: { nonceHash, deviceKeyThumbprint } },
    });
    if (reusedNonce) throw new LicenseAPIError("ACTIVATE_PROOF_REPLAYED", 401, "无法验证当前设备，请重试。");
  }

  private async consumeProofNonce(
    tx: Prisma.TransactionClient,
    nonceHash: string,
    deviceKeyThumbprint: string,
  ): Promise<void> {
    try {
      await tx.activateProofNonce.create({
        data: {
          nonceHash,
          deviceKeyThumbprint,
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1_000),
          consumedAt: new Date(),
        },
      });
    } catch {
      throw new LicenseAPIError("ACTIVATE_PROOF_REPLAYED", 401, "无法验证当前设备，请重试。");
    }
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
