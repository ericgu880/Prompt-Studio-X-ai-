import { randomBytes } from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { SecretBox } from "../src/crypto/secretBox.js";
import {
  EmailOutboxWorker,
  EmailTransportError,
  type EmailTransport,
} from "../src/services/EmailOutboxWorker.js";

function config(): AppConfig {
  return {
    commercial: {
      dataEncryptionKeyB64: randomBytes(32).toString("base64"),
      resendApiKey: "re_test",
      resendFromEmail: "PromptStudio <license@promptstudio.app>",
      supportURL: "https://promptstudio.app/support",
      workerLeaseMs: 30_000,
      workerMaxAttempts: 4,
    },
  } as AppConfig;
}

function fixture(appConfig: AppConfig) {
  const payloadEncrypted = new SecretBox(appConfig.commercial.dataEncryptionKeyB64).seal(JSON.stringify({
    version: 1,
    kind: "purchase",
    to: "buyer@example.com",
    emailMasked: "b***@example.com",
    licenseCode: "PS-2345-6789-ABCD-EFGH-JKLM",
    plan: "pro_lifetime",
    seats: 2,
    majorVersion: 1,
    updatesUntil: "2027-07-15T00:00:00.000Z",
  }));
  return {
    id: "outbox-1",
    kind: "purchase",
    idempotencyKey: "purchase:lemonsqueezy:42",
    payloadEncrypted,
    attemptCount: 0,
    nextAttemptAt: new Date("2026-07-15T00:00:00.000Z"),
    status: "pending",
    createdAt: new Date("2026-07-15T00:00:00.000Z"),
  };
}

function prismaStub(item: ReturnType<typeof fixture>) {
  const updates: unknown[] = [];
  return {
    updates,
    client: {
      emailOutbox: {
        findFirst: vi.fn().mockResolvedValue(item),
        updateMany: vi.fn().mockResolvedValue({ count: 1 }),
        update: vi.fn(async (input) => {
          updates.push(input);
          return input;
        }),
      },
    } as unknown as PrismaClient,
  };
}

describe("EmailOutboxWorker", () => {
  it("sends with a stable idempotency key and scrubs sensitive payload after acceptance", async () => {
    const appConfig = config();
    const item = fixture(appConfig);
    const prisma = prismaStub(item);
    const transport: EmailTransport = { send: vi.fn().mockResolvedValue({ id: "resend-1" }) };
    const worker = new EmailOutboxWorker(prisma.client, appConfig, transport);

    expect(await worker.runOnce(new Date("2026-07-15T00:00:01.000Z"))).toBe(true);

    expect(transport.send).toHaveBeenCalledWith(expect.objectContaining({
      to: "buyer@example.com",
      idempotencyKey: "purchase:lemonsqueezy:42",
      subject: expect.stringContaining("PromptStudio"),
    }));
    expect(prisma.updates.at(-1)).toMatchObject({
      data: {
        status: "accepted",
        providerMessageId: "resend-1",
        payloadEncrypted: null,
        leaseExpiresAt: null,
      },
    });
  });

  it("retries transient provider failures without clearing the payload", async () => {
    const appConfig = config();
    const item = fixture(appConfig);
    const prisma = prismaStub(item);
    const transport: EmailTransport = {
      send: vi.fn().mockRejectedValue(new EmailTransportError("RESEND_UNAVAILABLE", 503, true)),
    };
    const worker = new EmailOutboxWorker(prisma.client, appConfig, transport);

    await worker.runOnce(new Date("2026-07-15T00:00:01.000Z"));

    expect(prisma.updates.at(-1)).toMatchObject({
      data: {
        status: "pending",
        payloadEncrypted: item.payloadEncrypted,
        lastErrorCode: "RESEND_UNAVAILABLE",
      },
    });
  });
});
