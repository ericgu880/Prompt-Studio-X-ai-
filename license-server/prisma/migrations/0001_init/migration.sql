-- CreateEnum
CREATE TYPE "LicenseStatus" AS ENUM ('unused', 'active', 'limited', 'refunded', 'revoked', 'disabled');
CREATE TYPE "LicenseType" AS ENUM ('lifetime', 'subscription', 'trial', 'education', 'team', 'beta');
CREATE TYPE "ActivationStatus" AS ENUM ('active', 'deactivated', 'revoked', 'stale');
CREATE TYPE "EventSource" AS ENUM ('api', 'cli', 'system');

-- CreateTable
CREATE TABLE "Customer" (
    "id" TEXT NOT NULL,
    "emailHash" TEXT NOT NULL,
    "emailMasked" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "Customer_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "License" (
    "id" TEXT NOT NULL,
    "customerId" TEXT NOT NULL,
    "codePrefix" TEXT NOT NULL,
    "codeHash" TEXT NOT NULL,
    "codeMasked" TEXT NOT NULL,
    "plan" TEXT NOT NULL DEFAULT 'pro_lifetime',
    "licenseType" "LicenseType" NOT NULL DEFAULT 'lifetime',
    "status" "LicenseStatus" NOT NULL DEFAULT 'unused',
    "seatLimit" INTEGER NOT NULL DEFAULT 2,
    "majorVersion" INTEGER NOT NULL DEFAULT 1,
    "updatesUntil" TIMESTAMP(3),
    "orderProvider" TEXT,
    "orderId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "activatedAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),
    "revokedReason" TEXT,
    "refundedAt" TIMESTAMP(3),
    "notes" TEXT,
    CONSTRAINT "License_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "Activation" (
    "id" TEXT NOT NULL,
    "licenseId" TEXT NOT NULL,
    "installIdHash" TEXT NOT NULL,
    "devicePublicKey" TEXT NOT NULL,
    "deviceKeyThumbprint" TEXT NOT NULL,
    "deviceLabel" TEXT NOT NULL,
    "platform" TEXT NOT NULL DEFAULT 'macos',
    "osVersion" TEXT,
    "appVersion" TEXT,
    "status" "ActivationStatus" NOT NULL DEFAULT 'active',
    "activatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastSeenAt" TIMESTAMP(3),
    "deactivatedAt" TIMESTAMP(3),
    "deactivatedReason" TEXT,
    "replacedByActivationId" TEXT,
    CONSTRAINT "Activation_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "ActivateProofNonce" (
    "id" TEXT NOT NULL,
    "nonceHash" TEXT NOT NULL,
    "deviceKeyThumbprint" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ActivateProofNonce_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "RefreshChallenge" (
    "id" TEXT NOT NULL,
    "activationId" TEXT NOT NULL,
    "nonce" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "RefreshChallenge_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "LicenseCertificate" (
    "id" TEXT NOT NULL,
    "licenseId" TEXT NOT NULL,
    "activationId" TEXT NOT NULL,
    "kid" TEXT NOT NULL,
    "certificateHash" TEXT NOT NULL,
    "issuedAt" TIMESTAMP(3) NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "graceUntil" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "LicenseCertificate_pkey" PRIMARY KEY ("id")
);

CREATE TABLE "LicenseEvent" (
    "id" TEXT NOT NULL,
    "licenseId" TEXT,
    "activationId" TEXT,
    "eventType" TEXT NOT NULL,
    "eventSource" "EventSource" NOT NULL DEFAULT 'api',
    "emailHash" TEXT,
    "codePrefix" TEXT,
    "ipHash" TEXT,
    "userAgentHash" TEXT,
    "metadataJson" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "LicenseEvent_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "Customer_emailHash_key" ON "Customer"("emailHash");
CREATE UNIQUE INDEX "License_codeHash_key" ON "License"("codeHash");
CREATE INDEX "License_customerId_idx" ON "License"("customerId");
CREATE INDEX "License_codePrefix_idx" ON "License"("codePrefix");
CREATE INDEX "License_status_idx" ON "License"("status");
CREATE INDEX "Activation_licenseId_installIdHash_idx" ON "Activation"("licenseId", "installIdHash");
CREATE INDEX "Activation_licenseId_installIdHash_status_idx" ON "Activation"("licenseId", "installIdHash", "status");
CREATE INDEX "Activation_licenseId_status_idx" ON "Activation"("licenseId", "status");
CREATE INDEX "Activation_deviceKeyThumbprint_idx" ON "Activation"("deviceKeyThumbprint");
CREATE UNIQUE INDEX "ActivateProofNonce_nonceHash_deviceKeyThumbprint_key" ON "ActivateProofNonce"("nonceHash", "deviceKeyThumbprint");
CREATE INDEX "ActivateProofNonce_expiresAt_idx" ON "ActivateProofNonce"("expiresAt");
CREATE INDEX "RefreshChallenge_activationId_idx" ON "RefreshChallenge"("activationId");
CREATE INDEX "RefreshChallenge_expiresAt_idx" ON "RefreshChallenge"("expiresAt");
CREATE INDEX "LicenseCertificate_licenseId_idx" ON "LicenseCertificate"("licenseId");
CREATE INDEX "LicenseCertificate_activationId_idx" ON "LicenseCertificate"("activationId");
CREATE INDEX "LicenseEvent_licenseId_idx" ON "LicenseEvent"("licenseId");
CREATE INDEX "LicenseEvent_activationId_idx" ON "LicenseEvent"("activationId");
CREATE INDEX "LicenseEvent_eventType_idx" ON "LicenseEvent"("eventType");
CREATE INDEX "LicenseEvent_createdAt_idx" ON "LicenseEvent"("createdAt");

-- Partial unique active install index required by the PRD.
CREATE UNIQUE INDEX IF NOT EXISTS activation_unique_active_install
ON "Activation" ("licenseId", "installIdHash")
WHERE "status" = 'active';

-- AddForeignKey
ALTER TABLE "License" ADD CONSTRAINT "License_customerId_fkey" FOREIGN KEY ("customerId") REFERENCES "Customer"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "Activation" ADD CONSTRAINT "Activation_licenseId_fkey" FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "RefreshChallenge" ADD CONSTRAINT "RefreshChallenge_activationId_fkey" FOREIGN KEY ("activationId") REFERENCES "Activation"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "LicenseCertificate" ADD CONSTRAINT "LicenseCertificate_licenseId_fkey" FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "LicenseCertificate" ADD CONSTRAINT "LicenseCertificate_activationId_fkey" FOREIGN KEY ("activationId") REFERENCES "Activation"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
ALTER TABLE "LicenseEvent" ADD CONSTRAINT "LicenseEvent_licenseId_fkey" FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "LicenseEvent" ADD CONSTRAINT "LicenseEvent_activationId_fkey" FOREIGN KEY ("activationId") REFERENCES "Activation"("id") ON DELETE SET NULL ON UPDATE CASCADE;
