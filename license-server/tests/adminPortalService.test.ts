import { describe, expect, it, vi } from "vitest";
import type { PrismaClient } from "@prisma/client";
import { AdminPortalService } from "../src/services/AdminPortalService.js";
import { AdminAuthService } from "../src/services/AdminAuthService.js";
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

  it("lists delivery operations without encrypted payloads or recovery hashes", async () => {
    const prisma = {
      $transaction: vi.fn(async (queries) => Promise.all(queries)),
      emailOutbox: {
        count: vi.fn().mockResolvedValue(1),
        findMany: vi.fn().mockResolvedValue([{
          id: "email-1",
          kind: "recovery",
          licenseId: "license-1",
          status: "failed",
          provider: "resend",
          providerMessageId: null,
          attemptCount: 3,
          payloadEncrypted: "secret-ciphertext",
          nextAttemptAt: new Date("2026-07-15T00:00:00.000Z"),
          acceptedAt: null,
          deliveredAt: null,
          lastErrorCode: "RESEND_UNAVAILABLE",
          lastErrorMessage: "Transactional email delivery failed",
          createdAt: new Date("2026-07-15T00:00:00.000Z"),
          license: { customer: { emailMasked: "b***@example.com" } },
        }]),
      },
    } as unknown as PrismaClient;
    const service = new AdminPortalService(prisma, baseConfig);

    const result = await service.listEmailOutbox({ page: 1, pageSize: 20 });

    expect(result.items[0]).toMatchObject({
      id: "email-1",
      email: "b***@example.com",
      payloadAvailable: true,
      status: "failed",
      lastErrorMessage: "Transactional email delivery failed",
    });
    expect(JSON.stringify(result)).not.toContain("secret-ciphertext");
  });

  it("does not retry mail after the sensitive payload has been scrubbed", async () => {
    const tx = {
      emailOutbox: {
        findUnique: vi.fn().mockResolvedValue({ id: "email-1", status: "failed", payloadEncrypted: null }),
      },
    };
    const prisma = {
      $transaction: (action: (client: typeof tx) => unknown) => action(tx),
    } as unknown as PrismaClient;
    const service = new AdminPortalService(prisma, baseConfig);

    await expect(service.retryEmail({
      actor: { id: "admin-1", email: "admin@example.com" },
      outboxId: "email-1",
      reason: "customer_support",
      requestId: "req-1",
    })).rejects.toMatchObject({ code: "EMAIL_PAYLOAD_UNAVAILABLE" });
  });

  it("neutralizes spreadsheet formulas in license CSV exports", async () => {
    const prisma = {
      license: {
        findMany: vi.fn().mockResolvedValue([{
          id: "license-1",
          customer: { emailMasked: "=HYPERLINK(\"https://evil.example\")" },
          codeMasked: "PS-TEST",
          plan: "+SUM(1,1)",
          status: "active",
          seatLimit: 2,
          activations: [],
          orderProvider: "lemonsqueezy",
          orderId: "@malicious",
          createdAt: new Date("2026-07-15T00:00:00.000Z"),
          activatedAt: null,
          revokedAt: null,
        }]),
      },
    } as unknown as PrismaClient;
    const service = new AdminPortalService(prisma, baseConfig);

    const csv = await service.exportLicensesCsv();

    expect(csv).toContain("\"'=HYPERLINK(\"\"https://evil.example\"\")\"");
    expect(csv).toContain("\"'+SUM(1,1)\"");
    expect(csv).toContain("\"'@malicious\"");
    expect(csv).not.toContain("\"=HYPERLINK");
  });

  it("prevents an administrator from disabling the current or last active owner", async () => {
    const selfTx = {
      $queryRaw: vi.fn(async () => [{ pg_advisory_xact_lock: null }]),
      adminUser: {
        findUnique: vi.fn().mockResolvedValue({
          id: "admin-1",
          email: "owner@example.com",
          role: "owner",
          disabledAt: null,
        }),
        count: vi.fn().mockResolvedValue(2),
        update: vi.fn(),
      },
    };
    const selfService = new AdminPortalService({
      $transaction: (action: (client: typeof selfTx) => unknown) => action(selfTx),
    } as unknown as PrismaClient, baseConfig);
    await expect(selfService.disableAdminUser({
      actor: { id: "admin-1", email: "owner@example.com" },
      adminUserId: "admin-1",
      requestId: "req-self",
    })).rejects.toMatchObject({ code: "CANNOT_DISABLE_CURRENT_ADMIN" });

    const lastOwnerTx = {
      $queryRaw: vi.fn(async () => [{ pg_advisory_xact_lock: null }]),
      adminUser: {
        findUnique: vi.fn().mockResolvedValue({
          id: "admin-2",
          email: "last-owner@example.com",
          role: "owner",
          disabledAt: null,
        }),
        count: vi.fn().mockResolvedValue(1),
        update: vi.fn(),
      },
    };
    const lastOwnerService = new AdminPortalService({
      $transaction: (action: (client: typeof lastOwnerTx) => unknown) => action(lastOwnerTx),
    } as unknown as PrismaClient, baseConfig);
    await expect(lastOwnerService.disableAdminUser({
      actor: { id: "admin-1", email: "owner@example.com" },
      adminUserId: "admin-2",
      requestId: "req-last",
    })).rejects.toMatchObject({ code: "LAST_ACTIVE_OWNER" });
  });

  it("serializes concurrent owner disables so one active owner always remains", async () => {
    interface TestAdminUser {
      id: string;
      email: string;
      role: string;
      disabledAt: Date | null;
    }

    const users = new Map<string, TestAdminUser>([
      ["owner-1", { id: "owner-1", email: "owner-1@example.com", role: "owner", disabledAt: null }],
      ["owner-2", { id: "owner-2", email: "owner-2@example.com", role: "owner", disabledAt: null }],
    ]);
    const activeOwnerCount = () => [...users.values()].filter((user) => user.role === "owner" && !user.disabledAt).length;
    const unlockedCountReaders: Array<(count: number) => void> = [];
    let advisoryLockTail = Promise.resolve();

    const prisma = {
      $transaction: async (action: (client: unknown) => Promise<unknown>) => {
        let releaseAdvisoryLock: (() => void) | undefined;
        let advisoryLockHeld = false;
        const tx = {
          $queryRaw: vi.fn(async (query: TemplateStringsArray) => {
            expect(query.join("?")).toContain("pg_advisory_xact_lock");
            const previousLock = advisoryLockTail;
            let releaseCurrentLock!: () => void;
            advisoryLockTail = new Promise<void>((resolve) => {
              releaseCurrentLock = resolve;
            });
            await previousLock;
            advisoryLockHeld = true;
            releaseAdvisoryLock = releaseCurrentLock;
            return [{ pg_advisory_xact_lock: null }];
          }),
          adminUser: {
            findUnique: vi.fn(async ({ where }: { where: { id: string } }) => users.get(where.id) ?? null),
            count: vi.fn(async () => {
              if (advisoryLockHeld) return activeOwnerCount();
              return new Promise<number>((resolve) => {
                unlockedCountReaders.push(resolve);
                if (unlockedCountReaders.length === 2) {
                  const count = activeOwnerCount();
                  for (const reader of unlockedCountReaders.splice(0)) reader(count);
                }
              });
            }),
            update: vi.fn(async ({ where, data }: { where: { id: string }; data: { disabledAt: Date } }) => {
              const existing = users.get(where.id);
              if (!existing) throw new Error("Missing test admin user");
              const updated = { ...existing, disabledAt: data.disabledAt };
              users.set(where.id, updated);
              return updated;
            }),
          },
          adminSession: {
            updateMany: vi.fn(async () => ({ count: 0 })),
          },
          adminAuditLog: {
            create: vi.fn(async () => ({})),
          },
        };

        try {
          return await action(tx);
        } finally {
          releaseAdvisoryLock?.();
        }
      },
    } as unknown as PrismaClient;
    const service = new AdminPortalService(prisma, baseConfig);

    const results = await Promise.allSettled([
      service.disableAdminUser({
        actor: { id: "operator-1", email: "operator@example.com" },
        adminUserId: "owner-1",
        requestId: "req-owner-1",
      }),
      service.disableAdminUser({
        actor: { id: "operator-1", email: "operator@example.com" },
        adminUserId: "owner-2",
        requestId: "req-owner-2",
      }),
    ]);

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = results.filter((result) => result.status === "rejected");
    expect(rejected).toHaveLength(1);
    expect(rejected[0]).toMatchObject({ reason: { code: "LAST_ACTIVE_OWNER" } });
    expect(activeOwnerCount()).toBe(1);
  });
});

describe("AdminAuthService owner protection", () => {
  it("prevents the CLI from disabling the last active owner", async () => {
    const lastOwner = {
      id: "owner-1",
      email: "owner@example.com",
      role: "owner",
      disabledAt: null,
    };
    const tx = {
      $queryRaw: vi.fn(async () => [{ pg_advisory_xact_lock: null }]),
      adminUser: {
        findUniqueOrThrow: vi.fn(async () => lastOwner),
        count: vi.fn(async () => 1),
        update: vi.fn(async () => lastOwner),
      },
      adminSession: {
        updateMany: vi.fn(async () => ({ count: 0 })),
      },
      adminAuditLog: {
        create: vi.fn(async () => ({})),
      },
    };
    const prisma = {
      $transaction: (action: (client: typeof tx) => unknown) => action(tx),
    } as unknown as PrismaClient;
    const service = new AdminAuthService(prisma, baseConfig);

    await expect(service.disableUser("owner@example.com"))
      .rejects.toMatchObject({ code: "LAST_ACTIVE_OWNER" });
    expect(tx.$queryRaw).toHaveBeenCalledTimes(1);
    expect(tx.adminUser.update).not.toHaveBeenCalled();
  });
});
