import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { License, LicenseRecoveryToken, PrismaClient } from "@prisma/client";
import type { AppConfig } from "../config.js";
import { hashEmail, maskEmail, normalizeEmail } from "../crypto/email.js";
import { SecretBox } from "../crypto/secretBox.js";

export class RecoveryTokenError extends Error {
  constructor(public readonly code: "RECOVERY_TOKEN_INVALID" | "RECOVERY_TOKEN_EXPIRED") {
    super(code);
  }
}

export class RecoveryService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
  ) {}

  async request(
    email: string,
    options: { now?: Date; requestIpHash?: string } = {},
  ): Promise<{ queued: boolean }> {
    const now = options.now ?? new Date();
    const normalizedEmail = normalizeEmail(email);
    const emailHash = hashEmail(this.config.licenseCodePepper, normalizedEmail);
    const customer = await this.prisma.customer.findUnique({
      where: { emailHash },
      include: {
        licenses: {
          where: { status: { in: ["unused", "active", "limited"] } },
          orderBy: { createdAt: "desc" },
          take: 1,
        },
      },
    });
    const license = customer?.licenses[0];
    if (!license) return { queued: false };

    const cooldownStart = new Date(now.getTime() - this.config.commercial.recoveryCooldownSeconds * 1_000);
    const recent = await this.prisma.licenseRecoveryToken.findFirst({
      where: { requestEmailHash: emailHash, createdAt: { gte: cooldownStart } },
      select: { id: true },
    });
    if (recent) return { queued: false };

    const rawToken = randomBytes(32).toString("base64url");
    const tokenHash = this.hashToken(rawToken);
    const tokenId = randomUUID();
    const expiresAt = new Date(now.getTime() + this.config.commercial.recoveryTokenMinutes * 60 * 1_000);
    const recoveryURL = `${this.config.commercial.publicBaseURL}/recover#token=${encodeURIComponent(rawToken)}`;
    const payloadEncrypted = new SecretBox(this.config.commercial.dataEncryptionKeyB64).seal(JSON.stringify({
      version: 1,
      kind: "recovery",
      to: normalizedEmail,
      emailMasked: maskEmail(normalizedEmail),
      recoveryURL,
      recoveryToken: rawToken,
      expiresAt: expiresAt.toISOString(),
    }));

    await this.prisma.$transaction(async (tx) => {
      await tx.licenseRecoveryToken.create({
        data: {
          id: tokenId,
          licenseId: license.id,
          tokenHash,
          requestEmailHash: emailHash,
          requestIpHash: options.requestIpHash,
          expiresAt,
          createdAt: now,
        },
      });
      await tx.emailOutbox.create({
        data: {
          kind: "recovery",
          licenseId: license.id,
          recoveryTokenId: tokenId,
          recipientHash: emailHash,
          idempotencyKey: `recovery:${tokenId}`,
          payloadEncrypted,
          createdAt: now,
        },
      });
      await tx.licenseEvent.create({
        data: {
          licenseId: license.id,
          eventType: "license_recovery_requested",
          eventSource: "api",
          emailHash,
        },
      });
    });
    return { queued: true };
  }

  async resolve(rawToken: string, now = new Date()): Promise<LicenseRecoveryToken & { license: License }> {
    const token = await this.prisma.licenseRecoveryToken.findUnique({
      where: { tokenHash: this.hashToken(rawToken) },
      include: { license: true },
    });
    if (!token || token.consumedAt) throw new RecoveryTokenError("RECOVERY_TOKEN_INVALID");
    if (token.expiresAt <= now) throw new RecoveryTokenError("RECOVERY_TOKEN_EXPIRED");
    return token;
  }

  hashToken(rawToken: string): string {
    return createHash("sha256").update(rawToken).digest("hex");
  }
}
