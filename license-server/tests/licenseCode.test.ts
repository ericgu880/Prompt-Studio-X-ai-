import { describe, expect, it } from "vitest";
import { generateLicenseCode, hashLicenseCode, maskLicenseCode, normalizeLicenseCode } from "../src/crypto/licenseCode.js";

describe("license codes", () => {
  it("generates display codes in the PromptStudio format", () => {
    const code = generateLicenseCode();
    expect(code).toMatch(/^PS-[23456789ABCDEFGHJKMNPQRSTVWXYZ]{4}(-[23456789ABCDEFGHJKMNPQRSTVWXYZ]{4}){4}$/);
  });

  it("normalizes lowercase, spaces, and hyphens", () => {
    expect(normalizeLicenseCode(" ps 7k4d-m9qf ")).toBe("PS7K4DM9QF");
  });

  it("hashes normalized inputs consistently", () => {
    const pepper = "test-pepper";
    expect(hashLicenseCode(pepper, "PS-7K4D-M9QF")).toBe(hashLicenseCode(pepper, "ps 7k4d m9qf"));
  });

  it("masks without leaking the full code", () => {
    const masked = maskLicenseCode("PS-7K4D-M9QF-2X8P-R6TA-B3HE");
    expect(masked).toBe("PS-7K4D-****-****-B3HE");
    expect(masked).not.toContain("M9QF");
  });
});
