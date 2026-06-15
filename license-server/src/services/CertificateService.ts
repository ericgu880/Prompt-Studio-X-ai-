import type { Activation, License, Prisma, PrismaClient } from "@prisma/client";
import { privateKeyFromPKCS8DerBase64 } from "../crypto/signing.js";
import { certificateHash, signCertificate } from "../crypto/certificate.js";
import type { AppConfig } from "../config.js";

const PRO_FEATURES = [
  "pro.create_prompt",
  "pro.edit_prompt",
  "pro.duplicate_prompt",
  "pro.manage_tags",
  "pro.manage_collections",
  "pro.templates",
  "pro.custom_variables",
  "pro.single_import",
  "pro.batch_import",
  "pro.advanced_search",
  "pro.ai_assist",
  "pro.advanced_export",
  "pro.automation"
];

function addDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

export class CertificateService {
  private readonly privateKey;

  constructor(private readonly prisma: PrismaClient, private readonly config: AppConfig) {
    this.privateKey = privateKeyFromPKCS8DerBase64(config.signingPrivateKeyPKCS8DerB64);
  }

  async issue(input: {
    license: License;
    activation: Activation;
    customerEmailHash: string;
    now?: Date;
    tx?: Prisma.TransactionClient;
  }): Promise<{
    certificate: string;
    issuedAt: Date;
    refreshAfter: Date;
    expiresAt: Date;
    graceUntil: Date;
  }> {
    const issuedAt = input.now ?? new Date();
    const refreshAfter = addDays(issuedAt, this.config.refreshAfterDays);
    const expiresAt = addDays(issuedAt, this.config.certificateDays);
    const graceUntil = addDays(expiresAt, this.config.graceDays);
    const certificate = signCertificate(
      {
        iss: this.config.certificateIssuer,
        aud: this.config.certificateAudience,
        bundleId: this.config.bundleId,
        licenseId: input.license.id,
        activationId: input.activation.id,
        customerEmailHash: input.customerEmailHash,
        plan: input.license.plan,
        licenseType: input.license.licenseType,
        status: "active",
        seatLimit: input.license.seatLimit,
        features: PRO_FEATURES,
        majorVersion: input.license.majorVersion,
        updatesUntil: input.license.updatesUntil?.toISOString() ?? null,
        deviceKeyThumbprint: input.activation.deviceKeyThumbprint,
        issuedAt: issuedAt.toISOString(),
        refreshAfter: refreshAfter.toISOString(),
        expiresAt: expiresAt.toISOString(),
        graceUntil: graceUntil.toISOString(),
        serverTime: issuedAt.toISOString()
      },
      this.config.signingKeyId,
      this.privateKey
    );

    const client = input.tx ?? this.prisma;
    await client.licenseCertificate.create({
      data: {
        licenseId: input.license.id,
        activationId: input.activation.id,
        kid: this.config.signingKeyId,
        certificateHash: certificateHash(certificate),
        issuedAt,
        expiresAt,
        graceUntil
      }
    });

    return { certificate, issuedAt, refreshAfter, expiresAt, graceUntil };
  }
}
