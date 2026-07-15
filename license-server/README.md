# PromptStudio License Server

Commercial license service for PromptStudio. It handles Lemon Squeezy order fulfillment, activation, device seats, recovery links, certificate refresh, Resend delivery, and the authenticated operations API.

## Local Setup

```bash
cd license-server
cp .env.example .env
npm install
docker compose up -d
npm run prisma:migrate
npm run dev
```

For local development, `tests/fixtures/ed25519_dev_private.pkcs8.der.b64` matches the macOS app fallback public key. Copy it into `.env`:

```bash
LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64=$(cat tests/fixtures/ed25519_dev_private.pkcs8.der.b64)
LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL=$(cat tests/fixtures/ed25519_dev_public.raw.b64url)
LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64=$(cat tests/fixtures/ed25519_dev_public.spki.der.b64)
LICENSE_SIGNING_KEY_ID=dev-key-1
```

Enable the web admin by setting strong random values in `.env`:

```bash
ADMIN_TOKEN=$(openssl rand -base64 32)
ADMIN_SESSION_SECRET=$(openssl rand -base64 32)
ADMIN_CSRF_SECRET=$(openssl rand -base64 32)
ADMIN_HMAC_SECRET=$(openssl rand -base64 32)
DATA_ENCRYPTION_KEY_B64=$(openssl rand -base64 32)
```

Use `npm run cli -- keys:generate-dev` only when rotating development keys. If you generate a new key, launch the macOS app with `PROMPTSTUDIO_LICENSE_PUBLIC_KEY_RAW_B64URL` set to the generated raw public key or replace the embedded app public key before building.

## Web Admin

Open the admin portal after the server starts:

```text
http://localhost:8787/admin
```

The Ant Design admin at `../promptstudio-admin` uses `/admin-api` and supports:

- create a license and show the plaintext activation code once
- search/list licenses
- view license detail, devices, and recent audit events
- add seats
- revoke a license
- deactivate a device
- rotate an activation code and show the new code once
- inspect and replay failed payment events
- inspect delivery state and retry eligible failed emails
- inspect active, consumed, and expired recovery requests
- audit every operator mutation with an explicit reason

The admin portal uses `ADMIN_TOKEN` login plus an HttpOnly signed session cookie. Put it behind HTTPS and do not expose it without a reverse proxy or access control in production.

## Create A Test License

```bash
npm run cli -- license:create --email user@example.com --plan pro_lifetime --seats 2
```

The plaintext license code is printed only once. Store it in the purchase email.

## API

- `GET /health`
- `POST /v1/licenses/activate`
- `POST /v1/licenses/recovery/activate`
- `POST /v1/licenses/refresh/challenge`
- `POST /v1/licenses/refresh`
- `POST /v1/licenses/deactivate`
- `POST /v1/licenses/recover`
- `POST /v1/webhooks/lemonsqueezy`
- `POST /v1/webhooks/resend`

## Production Deployment

The recommended first deployment is one Railway service plus Railway PostgreSQL. Set the service root to `license-server`, build with the included `Dockerfile`, run `npm run prisma:deploy` as the pre-deploy command, and use `/health` for the health check.

Required production settings:

```text
NODE_ENV=production
PUBLIC_BASE_URL=https://license.promptstudio.app
ADMIN_WEB_ORIGIN=https://license.promptstudio.app
LEGACY_ADMIN_ENABLED=false
WORKER_ENABLED=true
```

Also set every secret and mapping from `.env.example`. `COMMERCE_PRODUCT_MAPPINGS_JSON` is the allowlist that maps a Lemon Squeezy variant to `pro_lifetime`, seat count, major version, and update entitlement. Unknown variants fail closed and appear in the commercial operations page.

Configure provider webhooks after DNS and HTTPS are live:

```text
Lemon Squeezy: https://license.promptstudio.app/v1/webhooks/lemonsqueezy
Resend:        https://license.promptstudio.app/v1/webhooks/resend
```

Subscribe Lemon Squeezy to `order_created` and `order_refunded`. Subscribe Resend to delivered, delayed, and bounced delivery events. Keep webhook signing secrets separate from API keys.

Serve the compiled Ant Design admin and `/admin-api` on the same HTTPS origin, or place both behind one reverse proxy. The frontend intentionally uses relative `/admin-api` URLs so session and CSRF cookies remain first-party.

Before release:

```bash
npm ci
npm run prisma:generate
npm run build
npm test
npm run prisma:deploy
```

The complete commercial journey test requires an isolated PostgreSQL database or schema whose name contains `test`:

```bash
TEST_DATABASE_URL='postgresql://.../promptstudio_license_test' \
npm test -- commercialFlow.integration.test.ts
```

It covers signed and duplicate purchase webhooks, purchase mail, activation, seat conflict and replacement, recovery activation, refresh, and full-refund revocation. The test refuses to run against a database or schema without `test` in its name.

## Security Notes

- `LICENSE_CODE_PEPPER` must be backed up. Losing it makes existing license codes unverifiable.
- `DATA_ENCRYPTION_KEY_B64` must be backed up. Losing it makes queued webhook and email payloads unrecoverable.
- Production private keys must use Ed25519 PKCS8 DER standard base64 in `LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64`.
- The macOS app must only embed the raw 32 byte Ed25519 public key as base64url.
- The checked-in development key fixture is not a production secret.
- Never log full license codes, device private keys, signing private keys, peppers, tokens, or PromptStudio user content.

Release packaging must receive the matching public key. The build script writes only the public key into the App bundle and never copies the private key:

```bash
LICENSE_SIGNING_KEY_ID=prod-2026-01 \
LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL='...' \
SIGN_IDENTITY='Developer ID Application: ...' \
Scripts/build_app.sh release
```

Release packaging fails when the public key is missing. Debug builds may use the repository test key for local QA only.
