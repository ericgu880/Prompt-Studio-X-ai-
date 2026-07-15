-- Persist order-level state so refund and purchase webhooks remain correct when
-- they arrive out of order or are processed concurrently by multiple workers.
CREATE TABLE "CommerceOrderState" (
    "id" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "orderId" TEXT NOT NULL,
    "fullRefund" BOOLEAN NOT NULL DEFAULT false,
    "refundedAmount" INTEGER NOT NULL DEFAULT 0,
    "orderTotal" INTEGER NOT NULL DEFAULT 0,
    "refundedAt" TIMESTAMP(3),
    "appliedAt" TIMESTAMP(3),
    "lastObservedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "CommerceOrderState_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "CommerceOrderState_provider_orderId_key"
ON "CommerceOrderState"("provider", "orderId");

CREATE INDEX "CommerceOrderState_fullRefund_appliedAt_idx"
ON "CommerceOrderState"("fullRefund", "appliedAt");
