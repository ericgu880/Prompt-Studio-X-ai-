import type { PrismaClient } from "@prisma/client";
import type { AppConfig } from "../config.js";
import { SecretBox } from "../crypto/secretBox.js";
import { renderLicenseEmail, type LicenseEmailPayload } from "./EmailOutboxService.js";

export interface EmailTransport {
  send(input: {
    from: string;
    to: string;
    subject: string;
    html: string;
    text: string;
    idempotencyKey: string;
  }): Promise<{ id: string }>;
}

export class EmailTransportError extends Error {
  constructor(
    public readonly code: string,
    public readonly statusCode: number | undefined,
    public readonly retryable: boolean,
  ) {
    super(code);
  }
}

class ResendEmailTransport implements EmailTransport {
  constructor(private readonly apiKey: string | undefined) {}

  async send(input: Parameters<EmailTransport["send"]>[0]): Promise<{ id: string }> {
    if (!this.apiKey) throw new EmailTransportError("RESEND_NOT_CONFIGURED", undefined, false);
    let response: Response;
    try {
      response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": input.idempotencyKey,
        },
        body: JSON.stringify({
          from: input.from,
          to: [input.to],
          subject: input.subject,
          html: input.html,
          text: input.text,
        }),
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new EmailTransportError("RESEND_UNAVAILABLE", undefined, true);
    }
    if (!response.ok) {
      throw new EmailTransportError(
        response.status === 429 ? "RESEND_RATE_LIMITED" : "RESEND_REJECTED",
        response.status,
        response.status === 429 || response.status >= 500,
      );
    }
    const data = await response.json() as { id?: string };
    if (!data.id) throw new EmailTransportError("RESEND_INVALID_RESPONSE", response.status, true);
    return { id: data.id };
  }
}

export class EmailOutboxWorker {
  private timer?: NodeJS.Timeout;
  private running = false;
  private stopping = false;
  private currentDrain?: Promise<void>;
  private readonly transport: EmailTransport;

  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
    transport?: EmailTransport,
    private readonly onDrainError: (error: unknown) => void = () => {},
  ) {
    this.transport = transport ?? new ResendEmailTransport(config.commercial?.resendApiKey);
  }

  async runOnce(now = new Date()): Promise<boolean> {
    const item = await this.prisma.emailOutbox.findFirst({
      where: {
        nextAttemptAt: { lte: now },
        OR: [
          { status: "pending" },
          { status: "processing", leaseExpiresAt: { lt: now } },
        ],
      },
      orderBy: { createdAt: "asc" },
    });
    if (!item) return false;

    const claim = await this.prisma.emailOutbox.updateMany({
      where: {
        id: item.id,
        nextAttemptAt: { lte: now },
        OR: [
          { status: "pending" },
          { status: "processing", leaseExpiresAt: { lt: now } },
        ],
      },
      data: {
        status: "processing",
        leaseExpiresAt: new Date(now.getTime() + this.config.commercial.workerLeaseMs),
        attemptCount: { increment: 1 },
      },
    });
    if (claim.count !== 1) return true;

    try {
      if (!item.payloadEncrypted) throw new EmailTransportError("EMAIL_PAYLOAD_MISSING", undefined, false);
      const payload = JSON.parse(this.secretBox().open(item.payloadEncrypted)) as LicenseEmailPayload;
      const rendered = renderLicenseEmail(payload, this.config);
      const result = await this.transport.send({
        from: this.config.commercial.resendFromEmail,
        ...rendered,
        idempotencyKey: item.idempotencyKey,
      });
      await this.prisma.emailOutbox.update({
        where: { id: item.id },
        data: {
          status: "accepted",
          providerMessageId: result.id,
          acceptedAt: new Date(),
          payloadEncrypted: null,
          payloadClearedAt: new Date(),
          leaseExpiresAt: null,
          lastErrorCode: null,
          lastErrorMessage: null,
        },
      });
    } catch (error) {
      const attempt = item.attemptCount + 1;
      const known = error instanceof EmailTransportError ? error : null;
      const failed = known ? !known.retryable : false;
      const terminal = failed || attempt >= this.config.commercial.workerMaxAttempts;
      await this.prisma.emailOutbox.update({
        where: { id: item.id },
        data: {
          status: terminal ? "failed" : "pending",
          payloadEncrypted: item.payloadEncrypted,
          leaseExpiresAt: null,
          nextAttemptAt: terminal
            ? item.nextAttemptAt
            : new Date(now.getTime() + Math.min(60 * 60 * 1_000, 2 ** attempt * 1_000)),
          lastErrorCode: known?.code ?? "EMAIL_SEND_FAILED",
          lastErrorMessage: "Transactional email delivery failed",
        },
      });
    }
    return true;
  }

  start(): void {
    if (this.timer || this.currentDrain || !this.config.commercial?.workerEnabled) return;
    this.stopping = false;
    this.timer = setInterval(() => {
      if (this.running) return;
      this.running = true;
      const drain = this.drain().catch((error) => { this.onDrainError(error); });
      this.currentDrain = drain;
      void drain.finally(() => {
        if (this.currentDrain === drain) this.currentDrain = undefined;
        this.running = false;
      });
    }, this.config.commercial.workerPollIntervalMs);
    this.timer.unref();
  }

  stop(): void {
    this.stopping = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async stopAndDrain(timeoutMs = 10_000): Promise<void> {
    this.stop();
    const drain = this.currentDrain;
    if (!drain) return;

    let timeout: NodeJS.Timeout | undefined;
    const deadline = new Promise<void>((_resolve, reject) => {
      timeout = setTimeout(() => {
        reject(new Error(`EmailOutboxWorker did not stop within ${timeoutMs}ms`));
      }, timeoutMs);
      timeout.unref();
    });
    try {
      await Promise.race([drain, deadline]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  private async drain(): Promise<void> {
    for (let count = 0; count < 20; count += 1) {
      if (!(await this.runOnce()) || this.stopping) return;
    }
  }

  private secretBox(): SecretBox {
    return new SecretBox(this.config.commercial.dataEncryptionKeyB64);
  }
}
