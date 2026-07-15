import { createHash } from "node:crypto";
import { Prisma, type PrismaClient } from "@prisma/client";
import type { AppConfig } from "../config.js";
import { SecretBox } from "../crypto/secretBox.js";
import {
  CommerceFulfillmentError,
  type CommerceFulfillmentService,
} from "./CommerceFulfillmentService.js";

export class CommerceInboxWorker {
  private timer?: NodeJS.Timeout;
  private running = false;

  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
    private readonly fulfillment: CommerceFulfillmentService,
  ) {}

  async enqueue(input: {
    provider: string;
    eventName: string;
    providerEventId?: string;
    rawBody: Buffer;
  }): Promise<{ created: boolean; id: string }> {
    const payloadHash = createHash("sha256").update(input.rawBody).digest("hex");
    try {
      const event = await this.prisma.commerceWebhookEvent.create({
        data: {
          provider: input.provider,
          eventName: input.eventName,
          providerEventId: input.providerEventId,
          payloadHash,
          payloadEncrypted: this.secretBox().seal(input.rawBody.toString("utf8")),
        },
      });
      return { created: true, id: event.id };
    } catch (error) {
      if (!(error instanceof Prisma.PrismaClientKnownRequestError) || error.code !== "P2002") throw error;
      const existing = await this.prisma.commerceWebhookEvent.findFirst({
        where: {
          provider: input.provider,
          OR: [
            { eventName: input.eventName, payloadHash },
            ...(input.providerEventId ? [{ providerEventId: input.providerEventId }] : []),
          ],
        },
        select: { id: true },
      });
      if (!existing) throw error;
      return { created: false, id: existing.id };
    }
  }

  async runOnce(now = new Date()): Promise<boolean> {
    const candidate = await this.prisma.commerceWebhookEvent.findFirst({
      where: {
        nextAttemptAt: { lte: now },
        OR: [
          { status: "pending" },
          { status: "processing", leaseExpiresAt: { lt: now } },
        ],
      },
      orderBy: { createdAt: "asc" },
    });
    if (!candidate) return false;

    const leaseExpiresAt = new Date(now.getTime() + this.config.commercial.workerLeaseMs);
    const claim = await this.prisma.commerceWebhookEvent.updateMany({
      where: {
        id: candidate.id,
        nextAttemptAt: { lte: now },
        OR: [
          { status: "pending" },
          { status: "processing", leaseExpiresAt: { lt: now } },
        ],
      },
      data: {
        status: "processing",
        leaseExpiresAt,
        attemptCount: { increment: 1 },
      },
    });
    if (claim.count !== 1) return true;

    try {
      await this.fulfillment.process({
        provider: candidate.provider,
        eventName: candidate.eventName,
        payload: JSON.parse(this.secretBox().open(candidate.payloadEncrypted)),
      });
      await this.prisma.commerceWebhookEvent.update({
        where: { id: candidate.id },
        data: {
          status: "completed",
          processedAt: new Date(),
          leaseExpiresAt: null,
          lastErrorCode: null,
          lastErrorMessage: null,
        },
      });
    } catch (error) {
      const attempt = candidate.attemptCount + 1;
      const retryable = !(error instanceof CommerceFulfillmentError) || error.retryable;
      const failed = !retryable || attempt >= this.config.commercial.workerMaxAttempts;
      const errorCode = error instanceof CommerceFulfillmentError ? error.code : "PROCESSING_FAILED";
      await this.prisma.commerceWebhookEvent.update({
        where: { id: candidate.id },
        data: {
          status: failed ? "failed" : "pending",
          leaseExpiresAt: null,
          nextAttemptAt: failed
            ? candidate.nextAttemptAt
            : new Date(now.getTime() + Math.min(60 * 60 * 1_000, 2 ** attempt * 1_000)),
          lastErrorCode: errorCode,
          lastErrorMessage: error instanceof CommerceFulfillmentError ? error.message : "Unexpected processing failure",
        },
      });
    }
    return true;
  }

  start(): void {
    if (this.timer || !this.config.commercial?.workerEnabled) return;
    this.timer = setInterval(() => {
      if (this.running) return;
      this.running = true;
      void this.drain().finally(() => {
        this.running = false;
      });
    }, this.config.commercial.workerPollIntervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  private async drain(): Promise<void> {
    for (let count = 0; count < 20; count += 1) {
      if (!(await this.runOnce())) return;
    }
  }

  private secretBox(): SecretBox {
    return new SecretBox(this.config.commercial.dataEncryptionKeyB64);
  }
}
