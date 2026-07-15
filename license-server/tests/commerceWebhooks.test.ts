import { createHmac } from "node:crypto";
import fastify from "fastify";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { commerceWebhookRoutes } from "../src/routes/commerceWebhooks.js";

const secret = "test-lemon-secret";
const enqueue = vi.fn();

function config(): AppConfig {
  return {
    commercial: {
      lemonSqueezyWebhookSecret: secret,
    },
  } as AppConfig;
}

async function testApp() {
  const app = fastify();
  app.decorate("licenseServices", { commerceInbox: { enqueue } } as never);
  await app.register(commerceWebhookRoutes, config());
  return app;
}

function signature(body: string): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}

describe("Lemon Squeezy webhooks", () => {
  beforeEach(() => {
    enqueue.mockReset();
    enqueue.mockResolvedValue({ created: true, id: "event-1" });
  });

  it("rejects missing or invalid signatures", async () => {
    const app = await testApp();
    const body = JSON.stringify({ meta: { event_name: "order_created" }, data: { id: "42" } });

    const missing = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-event-name": "order_created" },
      payload: body,
    });
    const invalid = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: {
        "content-type": "application/json",
        "x-event-name": "order_created",
        "x-signature": "00".repeat(32),
      },
      payload: body,
    });
    await app.close();

    expect(missing.statusCode).toBe(401);
    expect(invalid.statusCode).toBe(401);
    expect(enqueue).not.toHaveBeenCalled();
  });

  it("durably accepts a valid event using the exact request bytes", async () => {
    const app = await testApp();
    const body = '{"meta":{"event_name":"order_created"},"data":{"id":"42"}}';
    const response = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: {
        "content-type": "application/json",
        "x-event-name": "order_created",
        "x-signature": signature(body),
      },
      payload: body,
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true, duplicate: false });
    expect(enqueue).toHaveBeenCalledWith({
      provider: "lemonsqueezy",
      eventName: "order_created",
      providerEventId: "order_created:42",
      rawBody: Buffer.from(body),
    });
  });

  it("acknowledges duplicate deliveries without enqueuing a second job", async () => {
    enqueue.mockResolvedValue({ created: false, id: "event-1" });
    const app = await testApp();
    const body = JSON.stringify({ meta: { event_name: "order_created" }, data: { id: "42" } });
    const response = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: {
        "content-type": "application/json",
        "x-event-name": "order_created",
        "x-signature": signature(body),
      },
      payload: body,
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true, duplicate: true });
  });
});
