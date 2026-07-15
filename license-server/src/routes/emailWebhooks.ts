import { createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";

function verifyResendSignature(input: {
  body: Buffer;
  id: string | undefined;
  timestamp: string | undefined;
  signature: string | undefined;
  secret: string | undefined;
}): boolean {
  if (!input.id || !input.timestamp || !input.signature || !input.secret) return false;
  const timestamp = Number(input.timestamp);
  if (!Number.isFinite(timestamp) || Math.abs(Date.now() / 1_000 - timestamp) > 5 * 60) return false;
  const encodedSecret = input.secret.startsWith("whsec_") ? input.secret.slice(6) : input.secret;
  let secret: Buffer;
  try {
    secret = Buffer.from(encodedSecret, "base64");
  } catch {
    return false;
  }
  const signed = `${input.id}.${input.timestamp}.${input.body.toString("utf8")}`;
  const expected = createHmac("sha256", secret).update(signed).digest();
  return input.signature.split(" ").some((part) => {
    const [version, value] = part.split(",", 2);
    if (version !== "v1" || !value) return false;
    const actual = Buffer.from(value, "base64");
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  });
}

function singleHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? undefined : value;
}

export async function emailWebhookRoutes(app: FastifyInstance, config: AppConfig): Promise<void> {
  app.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) => {
    done(null, body);
  });

  app.post("/v1/webhooks/resend", async (request, reply) => {
    const body = request.body as Buffer;
    if (!Buffer.isBuffer(body) || !verifyResendSignature({
      body,
      id: singleHeader(request.headers["svix-id"]),
      timestamp: singleHeader(request.headers["svix-timestamp"]),
      signature: singleHeader(request.headers["svix-signature"]),
      secret: config.commercial?.resendWebhookSecret,
    })) {
      return reply.code(401).send({ ok: false, error: { code: "INVALID_WEBHOOK_SIGNATURE" } });
    }
    let event: { type?: string; data?: { email_id?: string } };
    try {
      event = JSON.parse(body.toString("utf8"));
    } catch {
      return reply.code(400).send({ ok: false, error: { code: "INVALID_WEBHOOK_PAYLOAD" } });
    }
    if (event.type && event.data?.email_id) {
      await app.licenseServices.emailOutbox.recordProviderEvent({
        type: event.type,
        providerMessageId: event.data.email_id,
      });
    }
    return reply.send({ ok: true });
  });
}
