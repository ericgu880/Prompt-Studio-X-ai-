import "dotenv/config";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { stdin as input, stdout as output } from "node:process";
import { loadConfig } from "../config.js";
import { prisma } from "../db/prisma.js";
import { buildServices } from "../app.js";
import { generateEd25519KeyFixture } from "../crypto/signing.js";

function args(): { command: string; options: Map<string, string> } {
  const [, , command = "", ...rest] = process.argv;
  const options = new Map<string, string>();
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const value = rest[index + 1] && !rest[index + 1].startsWith("--") ? rest[++index] : "true";
    options.set(key, value);
  }
  return { command, options };
}

function requireOption(options: Map<string, string>, key: string): string {
  const value = options.get(key);
  if (!value) throw new Error(`Missing --${key}`);
  return value;
}

async function promptPassword(): Promise<string> {
  if (!input.isTTY) {
    const [password = "", confirmation = ""] = readFileSync(0, "utf8").split(/\r?\n/);
    if (password !== confirmation) throw new Error("Passwords do not match");
    if (password.length < 8) throw new Error("Password must be at least 8 characters");
    return password;
  }
  const rl = createInterface({ input, output });
  try {
    const password = await rl.question("Password: ");
    const confirmation = await rl.question("Confirm password: ");
    if (password !== confirmation) throw new Error("Passwords do not match");
    if (password.length < 8) throw new Error("Password must be at least 8 characters");
    return password;
  } finally {
    rl.close();
  }
}

async function requireInteractivePassword(options: Map<string, string>): Promise<string> {
  if (options.has("password")) {
    throw new Error("Do not pass --password. Passwords must be entered interactively.");
  }
  return promptPassword();
}

function fixturePath(name: string): string {
  const current = dirname(fileURLToPath(import.meta.url));
  return join(current, "../../tests/fixtures", name);
}

async function main(): Promise<void> {
  const { command, options } = args();

  if (command === "keys:generate-dev") {
    const fixture = generateEd25519KeyFixture();
    mkdirSync(dirname(fixturePath("placeholder")), { recursive: true });
    writeFileSync(fixturePath("ed25519_dev_private.pkcs8.der.b64"), `${fixture.privateKeyPKCS8DerB64}\n`);
    writeFileSync(fixturePath("ed25519_dev_public.raw.b64url"), `${fixture.publicKeyRawB64URL}\n`);
    writeFileSync(fixturePath("ed25519_dev_public.spki.der.b64"), `${fixture.publicKeySPKIDerB64}\n`);
    console.log("LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64=" + fixture.privateKeyPKCS8DerB64);
    console.log("LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL=" + fixture.publicKeyRawB64URL);
    console.log("LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64=" + fixture.publicKeySPKIDerB64);
    console.log("LICENSE_SIGNING_KEY_ID=dev-key-1");
    return;
  }

  const config = loadConfig();
  const services = buildServices(prisma, config);

  switch (command) {
    case "license:create": {
      const email = requireOption(options, "email");
      const plan = options.get("plan") ?? "pro_lifetime";
      const seats = Number(options.get("seats") ?? "2");
      const result = await services.licenses.createLicense({
        email,
        plan,
        seats,
        orderProvider: options.get("provider"),
        orderId: options.get("order-id")
      });
      console.log("License created.");
      console.log(`Email: ${result.emailMasked}`);
      console.log(`Plan: ${result.plan}`);
      console.log(`Seats: ${result.seats}`);
      console.log(`License code: ${result.licenseCode}`);
      console.log("");
      console.log("IMPORTANT: This license code is shown only once. Store it in the purchase email.");
      break;
    }
    case "license:list": {
      const licenses = await services.licenses.listLicenses(options.get("email"));
      for (const license of licenses) {
        console.log(`ID: ${license.id}`);
        console.log(`Email: ${license.email}`);
        console.log(`Code: ${license.code}`);
        console.log(`Plan: ${license.plan}`);
        console.log(`Status: ${license.status}`);
        console.log(`Seats: ${license.seats}`);
        console.log(`Active devices: ${license.activeDevices}`);
        console.log(`Created: ${license.createdAt.toISOString().slice(0, 10)}`);
        console.log("");
      }
      break;
    }
    case "license:add-seats": {
      await services.licenses.addSeats(requireOption(options, "license-id"), Number(requireOption(options, "seats")));
      console.log("Seats added.");
      break;
    }
    case "license:revoke": {
      await services.licenses.revokeLicense(requireOption(options, "license-id"), options.get("reason") ?? "manual");
      console.log("License revoked.");
      break;
    }
    case "license:deactivate-device": {
      await services.licenses.deactivateDevice(requireOption(options, "activation-id"), options.get("reason") ?? "support_request");
      console.log("Device deactivated.");
      break;
    }
    case "license:rotate-code": {
      const code = await services.licenses.rotateCode(requireOption(options, "license-id"), options.get("reason") ?? "manual");
      console.log("License code rotated.");
      console.log(`New license code: ${code}`);
      console.log("IMPORTANT: This license code is shown only once. Store it in the purchase email.");
      break;
    }
    case "admin:create-user": {
      const email = requireOption(options, "email");
      const password = await requireInteractivePassword(options);
      const user = await services.adminAuth.createUser(email, password);
      console.log(`Admin user created: ${user.email}`);
      break;
    }
    case "admin:set-password": {
      const email = requireOption(options, "email");
      const password = await requireInteractivePassword(options);
      await services.adminAuth.setPassword(email, password);
      console.log(`Admin password updated and sessions revoked: ${email.trim().toLowerCase()}`);
      break;
    }
    case "admin:disable-user": {
      const email = requireOption(options, "email");
      await services.adminAuth.disableUser(email);
      console.log(`Admin user disabled and sessions revoked: ${email.trim().toLowerCase()}`);
      break;
    }
    case "admin:revoke-sessions": {
      const email = requireOption(options, "email");
      await services.adminAuth.revokeSessions(email);
      console.log(`Admin sessions revoked: ${email.trim().toLowerCase()}`);
      break;
    }
    default:
      console.log(`Unknown command: ${command}`);
      console.log("Commands: keys:generate-dev, license:create, license:list, license:add-seats, license:revoke, license:deactivate-device, license:rotate-code, admin:create-user, admin:set-password, admin:disable-user, admin:revoke-sessions");
      process.exitCode = 1;
  }
}

try {
  await main();
} finally {
  await prisma.$disconnect();
}
