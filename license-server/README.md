# PromptStudio License Server

Phase 1 Activation Core MVP for PromptStudio.

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
```

Use `npm run cli -- keys:generate-dev` only when rotating development keys. If you generate a new key, launch the macOS app with `PROMPTSTUDIO_LICENSE_PUBLIC_KEY_RAW_B64URL` set to the generated raw public key or replace the embedded app public key before building.

## Web Admin

Open the admin portal after the server starts:

```text
http://localhost:8787/admin
```

Phase 1 admin supports:

- create a license and show the plaintext activation code once
- search/list licenses
- view license detail, devices, and recent audit events
- add seats
- revoke a license
- deactivate a device
- rotate an activation code and show the new code once

The admin portal uses `ADMIN_TOKEN` login plus an HttpOnly signed session cookie. Put it behind HTTPS and do not expose it without a reverse proxy or access control in production.

## Create A Test License

```bash
npm run cli -- license:create --email user@example.com --plan pro_lifetime --seats 2
```

The plaintext license code is printed only once. Store it in the purchase email.

## API

- `GET /health`
- `POST /v1/licenses/activate`
- `POST /v1/licenses/refresh/challenge`
- `POST /v1/licenses/refresh`
- `POST /v1/licenses/deactivate`
- `POST /v1/licenses/recover`

## Security Notes

- `LICENSE_CODE_PEPPER` must be backed up. Losing it makes existing license codes unverifiable.
- Production private keys must use Ed25519 PKCS8 DER standard base64 in `LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64`.
- The macOS app must only embed the raw 32 byte Ed25519 public key as base64url.
- The checked-in development key fixture is not a production secret.
- Never log full license codes, device private keys, signing private keys, peppers, tokens, or PromptStudio user content.
