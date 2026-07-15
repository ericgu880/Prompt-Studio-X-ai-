import fastify from "fastify";
import { describe, expect, it, vi } from "vitest";
import { licenseRoutes } from "../src/routes/licenses.js";
import { RateLimitError } from "../src/services/RateLimitService.js";

describe("license API error mapping", () => {
  it("returns 429 and Retry-After when a rate-limit bucket is exhausted", async () => {
    const app = fastify();
    app.decorate("licenseServices", {
      rateLimit: {
        check: vi.fn(() => {
          throw new RateLimitError(37);
        }),
      },
      activation: {
        createRefreshChallenge: vi.fn(),
      },
    } as never);
    await app.register(licenseRoutes);

    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/refresh/challenge",
      payload: { activationId: "activation-1" },
    });
    await app.close();

    expect(response.statusCode).toBe(429);
    expect(response.headers["retry-after"]).toBe("37");
    expect(response.json()).toMatchObject({
      ok: false,
      error: { code: "RATE_LIMITED" },
    });
  });
});
