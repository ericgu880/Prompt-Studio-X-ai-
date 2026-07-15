-- CreateEnum
CREATE TYPE "CommerceEventStatus" AS ENUM ('pending', 'processing', 'completed', 'failed');
CREATE TYPE "EmailDeliveryStatus" AS ENUM ('pending', 'processing', 'accepted', 'delivered', 'delayed', 'bounced', 'failed');

-- AlterTable
ALTER TABLE "Customer"
ADD COLUMN "emailEncrypted" TEXT,
ADD COLUMN "emailEncryptionVersion" INTEGER;

-- CreateTable
CREATE TABLE "CommerceWebhookEvent" (
    "id" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "eventName" TEXT NOT NULL,
    "providerEventId" TEXT,
    "payloadHash" TEXT NOT NULL,
    "payloadEncrypted" TEXT NOT NULL,
    "encryptionVersion" INTEGER NOT NULL DEFAULT 1,
    "status" "CommerceEventStatus" NOT NULL DEFAULT 'pending',
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "nextAttemptAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "leaseExpiresAt" TIMESTAMP(3),
    "processedAt" TIMESTAMP(3),
    "lastErrorCode" TEXT,
    "lastErrorMessage" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "CommerceWebhookEvent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LicenseRecoveryToken" (
    "id" TEXT NOT NULL,
    "licenseId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "requestEmailHash" TEXT NOT NULL,
    "requestIpHash" TEXT,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "LicenseRecoveryToken_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EmailOutbox" (
    "id" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "licenseId" TEXT,
    "recoveryTokenId" TEXT,
    "recipientHash" TEXT NOT NULL,
    "idempotencyKey" TEXT NOT NULL,
    "payloadEncrypted" TEXT,
    "encryptionVersion" INTEGER NOT NULL DEFAULT 1,
    "provider" TEXT NOT NULL DEFAULT 'resend',
    "providerMessageId" TEXT,
    "status" "EmailDeliveryStatus" NOT NULL DEFAULT 'pending',
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "nextAttemptAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "leaseExpiresAt" TIMESTAMP(3),
    "acceptedAt" TIMESTAMP(3),
    "deliveredAt" TIMESTAMP(3),
    "payloadClearedAt" TIMESTAMP(3),
    "lastErrorCode" TEXT,
    "lastErrorMessage" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "EmailOutbox_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "CommerceWebhookEvent_provider_eventName_payloadHash_key"
ON "CommerceWebhookEvent"("provider", "eventName", "payloadHash");
CREATE UNIQUE INDEX "CommerceWebhookEvent_provider_providerEventId_key"
ON "CommerceWebhookEvent"("provider", "providerEventId");
CREATE INDEX "CommerceWebhookEvent_status_nextAttemptAt_idx"
ON "CommerceWebhookEvent"("status", "nextAttemptAt");
CREATE INDEX "CommerceWebhookEvent_leaseExpiresAt_idx"
ON "CommerceWebhookEvent"("leaseExpiresAt");

CREATE UNIQUE INDEX "LicenseRecoveryToken_tokenHash_key" ON "LicenseRecoveryToken"("tokenHash");
CREATE INDEX "LicenseRecoveryToken_licenseId_createdAt_idx" ON "LicenseRecoveryToken"("licenseId", "createdAt");
CREATE INDEX "LicenseRecoveryToken_requestEmailHash_createdAt_idx" ON "LicenseRecoveryToken"("requestEmailHash", "createdAt");
CREATE INDEX "LicenseRecoveryToken_expiresAt_consumedAt_idx" ON "LicenseRecoveryToken"("expiresAt", "consumedAt");

CREATE UNIQUE INDEX "EmailOutbox_recoveryTokenId_key" ON "EmailOutbox"("recoveryTokenId");
CREATE UNIQUE INDEX "EmailOutbox_idempotencyKey_key" ON "EmailOutbox"("idempotencyKey");
CREATE UNIQUE INDEX "EmailOutbox_providerMessageId_key" ON "EmailOutbox"("providerMessageId");
CREATE INDEX "EmailOutbox_licenseId_idx" ON "EmailOutbox"("licenseId");
CREATE INDEX "EmailOutbox_status_nextAttemptAt_idx" ON "EmailOutbox"("status", "nextAttemptAt");
CREATE INDEX "EmailOutbox_leaseExpiresAt_idx" ON "EmailOutbox"("leaseExpiresAt");
CREATE INDEX "EmailOutbox_recipientHash_createdAt_idx" ON "EmailOutbox"("recipientHash", "createdAt");

-- AddForeignKey
ALTER TABLE "LicenseRecoveryToken"
ADD CONSTRAINT "LicenseRecoveryToken_licenseId_fkey"
FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "EmailOutbox"
ADD CONSTRAINT "EmailOutbox_licenseId_fkey"
FOREIGN KEY ("licenseId") REFERENCES "License"("id") ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "EmailOutbox"
ADD CONSTRAINT "EmailOutbox_recoveryTokenId_fkey"
FOREIGN KEY ("recoveryTokenId") REFERENCES "LicenseRecoveryToken"("id") ON DELETE SET NULL ON UPDATE CASCADE;
