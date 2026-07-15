import fastify from "fastify";
import { describe, expect, it, vi } from "vitest";
import { licenseRoutes } from "../src/routes/licenses.js";
import { LicenseAPIError } from "../src/services/ActivationService.js";

function validProofBody(extra: Record<string, unknown> = {}) {
  return {
    activationId: "act_current",
    challengeId: "challenge_1",
    signature: "s".repeat(40),
    ...extra
  };
}

async function buildTestApp(activation: Record<string, unknown>) {
  const app = fastify();
  app.decorate("licenseServices", {
    rateLimit: { check: vi.fn() },
    activation: {
      listDevices: vi.fn(),
      renameDevice: vi.fn(),
      deactivateDeviceById: vi.fn(),
      ...activation
    }
  });
  await app.register(licenseRoutes);
  return app;
}

describe("license device management routes", () => {
  it("rejects unsigned device list requests", async () => {
    const app = await buildTestApp({});
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/devices/list",
      payload: { activationId: "act_current", challengeId: "challenge_1" }
    });
    await app.close();

    expect(response.statusCode).toBe(400);
    expect(response.json()).toMatchObject({ ok: false, error: { code: "INVALID_REQUEST", message: "请求格式不正确。" } });
    expect(response.json().requestId).toBeTruthy();
  });

  it("lists devices without sensitive fields", async () => {
    const listDevices = vi.fn(async () => ({
      seatLimit: 2,
      activeDeviceCount: 1,
      devices: [{
        activationId: "act_current",
        label: "MacBook Pro",
        status: "active",
        platform: "macos",
        appVersion: "1.0.0",
        osVersion: "macOS 15.0.0",
        activatedAt: "2026-06-17T00:00:00.000Z",
        lastSeenAt: null,
        isCurrent: true
      }]
    }));
    const app = await buildTestApp({ listDevices });
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/devices/list",
      payload: validProofBody()
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.body).not.toContain("devicePublicKey");
    expect(response.body).not.toContain("installIdHash");
    expect(response.body).not.toContain("emailHash");
    expect(response.json().devices[0].activationId).toBe("act_current");
  });

  it("renames a device with the trimmed label", async () => {
    const renameDevice = vi.fn(async () => undefined);
    const app = await buildTestApp({ renameDevice });
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/devices/rename",
      payload: validProofBody({ targetActivationId: "act_other", label: "  Office Mac  " })
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(renameDevice).toHaveBeenCalledWith(expect.objectContaining({
      targetActivationId: "act_other",
      label: "Office Mac"
    }));
  });

  it("rejects deactivating a device from another license", async () => {
    const deactivateDeviceById = vi.fn(async () => {
      throw new LicenseAPIError("DEVICE_NOT_FOUND", 404, "设备不存在或已停用。");
    });
    const app = await buildTestApp({ deactivateDeviceById });
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/devices/deactivate",
      payload: validProofBody({ targetActivationId: "act_foreign", reason: "user_requested" })
    });
    await app.close();

    expect(response.statusCode).toBe(404);
    expect(response.json().error.code).toBe("DEVICE_NOT_FOUND");
  });

  it("deactivates a remote device", async () => {
    const deactivateDeviceById = vi.fn(async () => undefined);
    const app = await buildTestApp({ deactivateDeviceById });
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/devices/deactivate",
      payload: validProofBody({ targetActivationId: "act_other", reason: "user_requested" })
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(deactivateDeviceById).toHaveBeenCalledWith(expect.objectContaining({
      targetActivationId: "act_other",
      reason: "user_requested"
    }));
  });

  it("returns seat conflict details under error.data with a request id", async () => {
    const activate = vi.fn(async () => {
      throw new LicenseAPIError("SEAT_LIMIT_EXCEEDED", 409, "该激活码已达到设备上限。", {
        deviceCount: 2,
        seatLimit: 2,
        devices: [{ activationId: "act_old", deviceLabel: "Office Mac", platform: "macos" }],
      });
    });
    const app = await buildTestApp({ activate });
    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/activate",
      payload: {
        email: "buyer@example.com",
        licenseCode: "PS-2345-6789-ABCD-EFGH-JKLM",
        installIdHash: "i".repeat(20),
        devicePublicKey: "p".repeat(40),
        deviceProof: {
          version: "PromptStudio-Activate-Proof-v1",
          clientNonce: "n".repeat(20),
          createdAt: new Date().toISOString(),
          signature: "s".repeat(40),
        },
        deviceLabel: "New Mac",
        bundleId: "com.creatigo.promptstudio",
      },
    });
    await app.close();

    expect(response.statusCode).toBe(409);
    expect(response.json()).toMatchObject({
      error: {
        code: "SEAT_LIMIT_EXCEEDED",
        data: { deviceCount: 2, seatLimit: 2, devices: [{ activationId: "act_old" }] },
      },
    });
    expect(response.json().deviceCount).toBeUndefined();
    expect(response.json().requestId).toBeTruthy();
  });
});
