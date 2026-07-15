import { describe, expect, it, vi } from "vitest";
import type { PrismaClient } from "@prisma/client";
import { AdminPortalService } from "../src/services/AdminPortalService.js";
import type { AppConfig } from "../src/config.js";

const baseConfig = {
  licenseCodePepper: "test-pepper"
} as AppConfig;

describe("AdminPortalService", () => {
  it("returns dashboard summary metrics from server-side aggregates", async () => {
    const prisma = {
      license: {
        count: vi.fn()
          .mockResolvedValueOnce(7)
          .mockResolvedValueOnce(2)
          .mockResolvedValueOnce(1),
        aggregate: vi.fn(async () => ({ _sum: { seatLimit: 10 } }))
      },
      activation: {
        count: vi.fn(async () => 4)
      },
      licenseEvent: {
        count: vi.fn()
          .mockResolvedValueOnce(3)
          .mockResolvedValueOnce(5)
      }
    } as unknown as PrismaClient;

    const service = new AdminPortalService(prisma, baseConfig);
    const summary = await service.dashboardSummary();

    expect(summary).toMatchObject({
      totalLicenses: 7,
      todayNewLicenses: 2,
      todayActivationSuccess: 3,
      todayActivationFailed: 5,
      activeDevices: 4,
      revokedLicenses: 1,
      totalSeats: 10,
      seatUsageRate: 0.4
    });
  });

  it("lists activations without sensitive device fields", async () => {
    const prisma = {
      $transaction: vi.fn(async (queries) => Promise.all(queries)),
      activation: {
        count: vi.fn(async () => 1),
        findMany: vi.fn(async () => [{
          id: "act_1",
          licenseId: "lic_1",
          deviceLabel: "Office Mac",
          status: "active",
          platform: "macos",
          appVersion: "1.0.0",
          osVersion: "15.5",
          activatedAt: new Date("2026-06-20T00:00:00.000Z"),
          lastSeenAt: null,
          deactivatedAt: null,
          deactivatedReason: null,
          devicePublicKey: "secret-public-key",
          installIdHash: "secret-install",
          license: {
            id: "lic_1",
            customer: { emailMasked: "b***@example.com" },
            codeMasked: "PS-ABCD-****-****-WXYZ",
            plan: "pro_lifetime",
            status: "active"
          }
        }])
      }
    } as unknown as PrismaClient;

    const service = new AdminPortalService(prisma, baseConfig);
    const result = await service.listActivations({ page: 1, pageSize: 20 });

    expect(result.items[0]).toEqual({
      id: "act_1",
      licenseId: "lic_1",
      email: "b***@example.com",
      code: "PS-ABCD-****-****-WXYZ",
      plan: "pro_lifetime",
      licenseStatus: "active",
      label: "Office Mac",
      status: "active",
      platform: "macos",
      appVersion: "1.0.0",
      osVersion: "15.5",
      activatedAt: new Date("2026-06-20T00:00:00.000Z"),
      lastSeenAt: null,
      deactivatedAt: null,
      deactivatedReason: null
    });
    expect(JSON.stringify(result)).not.toContain("secret-public-key");
    expect(JSON.stringify(result)).not.toContain("secret-install");
  });
});
