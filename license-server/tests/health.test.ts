import fastify from "fastify";
import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import { healthRoutes } from "../src/routes/health.js";

describe("health endpoints", () => {
  it("separates process liveness from database readiness", async () => {
    const queryRaw = vi.fn()
      .mockResolvedValueOnce([{ ready: 1 }])
      .mockResolvedValueOnce([{ migrationApplied: true }]);
    const app = fastify();
    await healthRoutes(app, { $queryRawUnsafe: queryRaw } as unknown as PrismaClient);

    const live = await app.inject({ method: "GET", url: "/health" });
    const ready = await app.inject({ method: "GET", url: "/ready" });
    await app.close();

    expect(live.statusCode).toBe(200);
    expect(live.json()).toEqual({ ok: true });
    expect(ready.statusCode).toBe(200);
    expect(ready.json()).toEqual({ ok: true });
    expect(queryRaw).toHaveBeenCalledTimes(2);
    expect(queryRaw.mock.calls[1]?.[1]).toBe("0004_commerce_order_reconciliation");
  });

  it("returns 503 when the required commerce reconciliation migration is not applied", async () => {
    const queryRaw = vi.fn()
      .mockResolvedValueOnce([{ ready: 1 }])
      .mockResolvedValueOnce([{ migrationApplied: false }]);
    const app = fastify();
    await healthRoutes(app, { $queryRawUnsafe: queryRaw } as unknown as PrismaClient);

    const response = await app.inject({ method: "GET", url: "/ready" });
    await app.close();

    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ ok: false, error: { code: "DEPENDENCY_UNAVAILABLE" } });
  });

  it("returns 503 without leaking database errors when dependencies are unavailable", async () => {
    const app = fastify();
    await healthRoutes(app, {
      $queryRawUnsafe: vi.fn().mockRejectedValue(new Error("postgresql://secret@db/internal")),
    } as unknown as PrismaClient);

    const response = await app.inject({ method: "GET", url: "/ready" });
    await app.close();

    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ ok: false, error: { code: "DEPENDENCY_UNAVAILABLE" } });
    expect(response.body).not.toContain("postgresql");
  });
});
