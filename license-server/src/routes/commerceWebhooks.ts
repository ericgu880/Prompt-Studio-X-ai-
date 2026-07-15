import { createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";

function validSignature(body: Buffer, signature: string | undefined, secret: string | undefined): boolean {
  if (!signature || !secret || !/^[a-f0-9]{64}$/i.test(signature)) return false;
  const expected = createHmac("sha256", secret).update(body).digest();
  const actual = Buffer.from(signature, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export async function commerceWebhookRoutes(app: FastifyInstance, config: AppConfig): Promise<void> {
  app.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) => {
    done(null, body);
  });

  app.post("/v1/webhooks/lemonsqueezy", async (request, reply) => {
    const rawBody = request.body as Buffer;
    const signature = request.headers["x-signature"];
    if (!Buffer.isBuffer(rawBody) || Array.isArray(signature) || !validSignature(
      rawBody,
      signature,
      config.commercial?.lemonSqueezyWebhookSecret,
    )) {
      return reply.code(401).send({ ok: false, error: { code: "INVALID_WEBHOOK_SIGNATURE" } });
    }

    let payload: { meta?: { event_name?: string } };
    try {
      payload = JSON.parse(rawBody.toString("utf8"));
    } catch {
      return reply.code(400).send({ ok: false, error: { code: "INVALID_WEBHOOK_PAYLOAD" } });
    }
    const headerEventName = request.headers["x-event-name"];
    const eventName = payload.meta?.event_name;
    if (!eventName) {
      return reply.code(400).send({ ok: false, error: { code: "MISSING_WEBHOOK_EVENT_NAME" } });
    }
    if (typeof headerEventName === "string" && headerEventName !== eventName) {
      return reply.code(400).send({ ok: false, error: { code: "WEBHOOK_EVENT_NAME_MISMATCH" } });
    }

    try {
      const result = await app.licenseServices.commerceInbox.enqueue({
        provider: "lemonsqueezy",
        eventName,
        rawBody,
      });
      return reply.send({ ok: true, duplicate: !result.created });
    } catch {
      return reply.code(503).send({ ok: false, error: { code: "WEBHOOK_STORAGE_UNAVAILABLE" } });
    }
  });
}
