import { randomBytes } from "node:crypto";
import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { SecretBox } from "../src/crypto/secretBox.js";
import {
  CommerceFulfillmentError,
  CommerceFulfillmentService,
} from "../src/services/CommerceFulfillmentService.js";
import { LicenseService } from "../src/services/LicenseService.js";

function config(): AppConfig {
  return {
    licenseCodePepper: "test-pepper",
    commercial: {
      commerceEnabled: true,
      emailEnabled: true,
      dataEncryptionKeyB64: randomBytes(32).toString("base64"),
      productMappings: [
        {
          provider: "lemonsqueezy",
          variantId: "987",
          plan: "pro_lifetime",
          seats: 2,
          majorVersion: 1,
          updatesDays: 365,
        },
      ],
    },
  } as AppConfig;
}

function orderPayload(overrides: Record<string, unknown> = {}) {
  return {
    meta: { event_name: "order_created" },
    data: {
      id: "order-42",
      attributes: {
        user_email: "Buyer@Example.com",
        created_at: "2026-07-15T00:00:00.000Z",
        total: 9900,
        refunded_amount: 0,
        first_order_item: { variant_id: 987 },
        ...overrides,
      },
    },
  };
}

describe("CommerceFulfillmentService", () => {
  it("maps a purchased variant to a perpetual license and 365 update days", async () => {
    const provisionLifetimeLicense = vi.fn().mockResolvedValue({ created: true, licenseId: "license-1" });
    const applyCommerceRefund = vi.fn();
    const service = new CommerceFulfillmentService(config(), {
      provisionLifetimeLicense,
      applyCommerceRefund,
    });

    await service.process({
      provider: "lemonsqueezy",
      eventName: "order_created",
      payload: orderPayload(),
    });

    expect(provisionLifetimeLicense).toHaveBeenCalledWith({
      email: "Buyer@Example.com",
      orderProvider: "lemonsqueezy",
      orderId: "order-42",
      plan: "pro_lifetime",
      seats: 2,
      majorVersion: 1,
      purchasedAt: new Date("2026-07-15T00:00:00.000Z"),
      updatesDays: 365,
    });
  });

  it("provisions an order once and encrypts the purchase email payload", async () => {
    const appConfig = config();
    const created: Record<string, any> = {};
    const tx = {
      commerceOrderState: {
        upsert: vi.fn().mockResolvedValue({
          id: "order-state-1",
          fullRefund: false,
          refundedAmount: 0,
          orderTotal: 0,
          refundedAt: null,
        }),
        update: vi.fn(),
      },
      license: {
        findUnique: vi.fn().mockResolvedValueOnce(null).mockResolvedValue({ id: "license-1" }),
        create: vi.fn(async ({ data }) => {
          created.license = data;
          return { ...data, id: "license-1", codePrefix: "PS-TEST" };
        }),
      },
      customer: {
        upsert: vi.fn(async ({ create }) => ({ ...create, id: "customer-1" })),
      },
      emailOutbox: {
        create: vi.fn(async ({ data }) => {
          created.outbox = data;
          return data;
        }),
      },
      licenseEvent: { create: vi.fn() },
    };
    const prisma = {
      $transaction: async (action: (client: typeof tx) => unknown) => action(tx),
      license: { findUnique: vi.fn() },
    } as unknown as PrismaClient;
    const service = new LicenseService(prisma, appConfig, {} as never);
    const input = {
      email: "buyer@example.com",
      orderProvider: "lemonsqueezy",
      orderId: "order-42",
      plan: "pro_lifetime" as const,
      seats: 2,
      majorVersion: 1,
      purchasedAt: new Date("2026-07-15T00:00:00.000Z"),
      updatesDays: 365,
    };

    expect(await service.provisionLifetimeLicense(input)).toEqual({ created: true, licenseId: "license-1" });
    expect(await service.provisionLifetimeLicense(input)).toEqual({ created: false, licenseId: "license-1" });
    expect(tx.license.create).toHaveBeenCalledTimes(1);
    expect(created.license.updatesUntil.toISOString()).toBe("2027-07-15T00:00:00.000Z");
    expect(created.outbox.payloadEncrypted).not.toContain("buyer@example.com");
    const payload = JSON.parse(new SecretBox(appConfig.commercial.dataEncryptionKeyB64).open(created.outbox.payloadEncrypted));
    expect(payload).toMatchObject({
      kind: "purchase",
      to: "buyer@example.com",
      seats: 2,
      updatesUntil: "2027-07-15T00:00:00.000Z",
    });
    expect(payload.licenseCode).toMatch(/^PS-/);
  });

  it("persists a full refund that arrives before its order and provisions no usable code", async () => {
    const appConfig = config();
    let orderState: Record<string, any> | null = null;
    let license: Record<string, any> | null = null;
    const events: Array<Record<string, any>> = [];
    const outboxCreate = vi.fn();
    const tx = {
      commerceOrderState: {
        upsert: vi.fn(async ({ create, update }) => {
          orderState = orderState
            ? { ...orderState, ...update }
            : {
                id: "order-state-1",
                fullRefund: false,
                refundedAmount: 0,
                orderTotal: 0,
                refundedAt: null,
                appliedAt: null,
                ...create,
              };
          return orderState;
        }),
        update: vi.fn(async ({ data }) => {
          orderState = { ...orderState, ...data };
          return orderState;
        }),
      },
      license: {
        findUnique: vi.fn(async () => license),
        create: vi.fn(async ({ data }) => {
          license = { id: "license-refunded", codePrefix: "PS-TEST", status: "unused", ...data };
          return license;
        }),
        update: vi.fn(async ({ data }) => {
          license = { ...license, ...data, status: data.status ?? license?.status };
          return license;
        }),
      },
      customer: {
        upsert: vi.fn(async ({ create }) => ({ ...create, id: "customer-1" })),
      },
      emailOutbox: { create: outboxCreate },
      licenseEvent: {
        create: vi.fn(async ({ data }) => {
          events.push(data);
          return data;
        }),
      },
    };
    const prisma = {
      $transaction: async (action: (client: typeof tx) => unknown) => action(tx),
      license: { findUnique: vi.fn() },
    } as unknown as PrismaClient;
    const service = new LicenseService(prisma, appConfig, {} as never);

    await expect(service.applyCommerceRefund({
      orderProvider: "lemonsqueezy",
      orderId: "order-early-refund",
      fullRefund: true,
      refundedAt: new Date("2026-07-15T00:01:00.000Z"),
      refundedAmount: 9900,
      orderTotal: 9900,
    })).resolves.toBeUndefined();

    await expect(service.provisionLifetimeLicense({
      email: "buyer@example.com",
      orderProvider: "lemonsqueezy",
      orderId: "order-early-refund",
      plan: "pro_lifetime",
      seats: 2,
      majorVersion: 1,
      purchasedAt: new Date("2026-07-15T00:00:00.000Z"),
      updatesDays: 365,
    })).resolves.toEqual({ created: true, licenseId: "license-refunded" });

    expect(license).toMatchObject({ status: "refunded" });
    expect(outboxCreate).not.toHaveBeenCalled();
    expect(events.map((event) => event.eventType)).toContain("license_refunded");
  });

  it("fails an unknown variant without creating an incorrect license", async () => {
    const provisionLifetimeLicense = vi.fn();
    const service = new CommerceFulfillmentService(config(), {
      provisionLifetimeLicense,
      applyCommerceRefund: vi.fn(),
    });

    await expect(
      service.process({
        provider: "lemonsqueezy",
        eventName: "order_created",
        payload: orderPayload({ first_order_item: { variant_id: 404 } }),
      }),
    ).rejects.toMatchObject<Partial<CommerceFulfillmentError>>({
      code: "UNKNOWN_PRODUCT_VARIANT",
      retryable: false,
    });
    expect(provisionLifetimeLicense).not.toHaveBeenCalled();
  });

  it("distinguishes full and partial refunds", async () => {
    const applyCommerceRefund = vi.fn();
    const service = new CommerceFulfillmentService(config(), {
      provisionLifetimeLicense: vi.fn(),
      applyCommerceRefund,
    });

    await service.process({
      provider: "lemonsqueezy",
      eventName: "order_refunded",
      payload: orderPayload({ refunded_amount: 9900 }),
    });
    await service.process({
      provider: "lemonsqueezy",
      eventName: "order_refunded",
      payload: orderPayload({ refunded_amount: 2500 }),
    });

    expect(applyCommerceRefund).toHaveBeenNthCalledWith(1, {
      orderProvider: "lemonsqueezy",
      orderId: "order-42",
      fullRefund: true,
      refundedAt: expect.any(Date),
      refundedAmount: 9900,
      orderTotal: 9900,
    });
    expect(applyCommerceRefund).toHaveBeenNthCalledWith(2, {
      orderProvider: "lemonsqueezy",
      orderId: "order-42",
      fullRefund: false,
      refundedAt: expect.any(Date),
      refundedAmount: 2500,
      orderTotal: 9900,
    });
  });

  it.each([
    { total: 0, refunded_amount: 0 },
    { total: 9900, refunded_amount: 0 },
    { total: 9900, refunded_amount: -1 },
    { total: 9900, refunded_amount: 9901 },
    { total: 9900.5, refunded_amount: 2500 },
    { total: 9900, refunded_amount: 2500.5 },
    { total: Number.MAX_SAFE_INTEGER + 1, refunded_amount: 2500 },
    { total: 9900, refunded_amount: Number.MAX_SAFE_INTEGER + 1 },
    { total: "9900", refunded_amount: 2500 },
    { total: 9900, refunded_amount: "2500" },
  ])("rejects invalid refund currency amounts: %o", async (amounts) => {
    const applyCommerceRefund = vi.fn();
    const service = new CommerceFulfillmentService(config(), {
      provisionLifetimeLicense: vi.fn(),
      applyCommerceRefund,
    });

    await expect(service.process({
      provider: "lemonsqueezy",
      eventName: "order_refunded",
      payload: orderPayload(amounts),
    })).rejects.toMatchObject<Partial<CommerceFulfillmentError>>({
      code: "INVALID_REFUND_AMOUNT",
      retryable: false,
    });
    expect(applyCommerceRefund).not.toHaveBeenCalled();
  });
});
