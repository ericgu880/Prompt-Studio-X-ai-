import { randomBytes } from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { CommerceInboxWorker } from "../src/services/CommerceInboxWorker.js";

function workerConfig(): AppConfig {
  return {
    commercial: {
      dataEncryptionKeyB64: randomBytes(32).toString("base64"),
      workerEnabled: true,
      workerPollIntervalMs: 10,
      workerLeaseMs: 30_000,
      workerMaxAttempts: 4,
    },
  } as AppConfig;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((fulfill) => { resolve = fulfill; });
  return { promise, resolve };
}

describe("CommerceInboxWorker scheduling", () => {
  afterEach(() => { vi.useRealTimers(); });

  it("reports a drain failure instead of creating an unhandled rejection", async () => {
    vi.useFakeTimers();
    const config = workerConfig();
    const onError = vi.fn();
    const worker = new CommerceInboxWorker({
      commerceWebhookEvent: { findFirst: vi.fn().mockRejectedValue(new Error("database unavailable")) },
    } as unknown as PrismaClient, config, {} as never, onError);

    worker.start();
    await vi.advanceTimersByTimeAsync(11);
    worker.stop();
    expect(onError).toHaveBeenCalledTimes(1);
  });

  it("waits for the current drain before shutdown completes", async () => {
    vi.useFakeTimers();
    const candidate = deferred<null>();
    const worker = new CommerceInboxWorker({
      commerceWebhookEvent: { findFirst: vi.fn().mockReturnValue(candidate.promise) },
    } as unknown as PrismaClient, workerConfig(), {} as never);

    worker.start();
    await vi.advanceTimersByTimeAsync(11);

    let stopped = false;
    const stopping = worker.stopAndDrain(1_000).then(() => { stopped = true; });
    await Promise.resolve();
    expect(stopped).toBe(false);

    candidate.resolve(null);
    await stopping;
    expect(stopped).toBe(true);
  });

  it("bounds shutdown when the current drain does not finish", async () => {
    vi.useFakeTimers();
    const candidate = deferred<null>();
    const worker = new CommerceInboxWorker({
      commerceWebhookEvent: { findFirst: vi.fn().mockReturnValue(candidate.promise) },
    } as unknown as PrismaClient, workerConfig(), {} as never);

    worker.start();
    await vi.advanceTimersByTimeAsync(11);
    const stopping = worker.stopAndDrain(50);
    const assertion = expect(stopping).rejects.toThrow(
      "CommerceInboxWorker did not stop within 50ms",
    );
    await vi.advanceTimersByTimeAsync(50);
    await assertion;

    candidate.resolve(null);
    await Promise.resolve();
  });
});
