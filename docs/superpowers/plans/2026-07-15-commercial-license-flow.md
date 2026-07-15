# Commercial License Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a production-ready lifetime-license flow from Lemon Squeezy purchase through Resend delivery, macOS activation, recovery, seat replacement, device management, and offline certificate refresh.

**Architecture:** Keep Fastify and PostgreSQL as the system of record. Verify and persist commerce events in a database Inbox, process them with a leased worker, and send transactional mail through an encrypted Outbox. The macOS app uses one state-driven license center and the existing device-proof/certificate design.

**Tech Stack:** Swift 6.2/SwiftUI/AppKit, Fastify 5, TypeScript 5.7, Prisma/PostgreSQL, Lemon Squeezy Webhooks, Resend HTTP API, Vitest.

## Global Constraints

- Production API origin is `https://license.promptstudio.app`; localhost remains available only through an explicit development override.
- First commercial product is a lifetime license with two seats and 365 days of updates.
- Existing local prompt data never leaves the App during license operations.
- Never log raw email, license code, recovery token, device private key, or encrypted payload.
- Keep all unrelated untracked files unchanged; stage only files named by each task.

---

### Task 1: Persistence, encryption, and configuration

**Files:**
- Modify: `license-server/prisma/schema.prisma`
- Create: `license-server/prisma/migrations/0003_commercial_license_flow/migration.sql`
- Modify: `license-server/src/config.ts`
- Create: `license-server/src/crypto/secretBox.ts`
- Test: `license-server/tests/secretBox.test.ts`

**Interfaces:**
- Produces `SecretBox.seal(plaintext)` and `SecretBox.open(envelope)` using AES-256-GCM.
- Adds `CommerceWebhookEvent`, `EmailOutbox`, and `LicenseRecoveryToken` models plus encrypted customer email columns.
- Adds validated config for data encryption, Lemon Squeezy, Resend, public base URL, product mapping, and worker cadence.

- [ ] Write tests proving encrypted values round-trip, use a random IV, and fail with the wrong key or modified authentication tag.
- [ ] Add the Prisma models and migration with unique webhook event keys, outbox idempotency keys, retry indexes, token hashes, expiry, and consumed timestamps.
- [ ] Parse required production secrets and a JSON product mapping whose entry shape is:

```ts
type ProductMapping = {
  provider: "lemonsqueezy";
  variantId: string;
  plan: "pro_lifetime";
  seats: number;
  majorVersion: number;
  updatesDays: 365;
};
```

- [ ] Run `cd license-server && npm test -- secretBox.test.ts` and `npm run build`.
- [ ] Commit only Task 1 files with `feat(license): add commercial fulfillment persistence`.

### Task 2: Provider-neutral commerce Inbox and Lemon Squeezy adapter

**Files:**
- Create: `license-server/src/services/CommerceFulfillmentService.ts`
- Create: `license-server/src/services/CommerceInboxWorker.ts`
- Create: `license-server/src/routes/commerceWebhooks.ts`
- Modify: `license-server/src/services/LicenseService.ts`
- Modify: `license-server/src/app.ts`
- Modify: `license-server/src/index.ts`
- Test: `license-server/tests/commerceWebhooks.test.ts`
- Test: `license-server/tests/commerceFulfillment.test.ts`

**Interfaces:**
- `POST /v1/webhooks/lemonsqueezy` verifies raw-body HMAC and stores an Inbox row.
- `CommerceInboxWorker.runOnce(now)` leases pending rows and calls `CommerceFulfillmentService.process(event)`.
- `LicenseService.provisionLifetimeLicense(...)` creates the customer/license/outbox records in one Prisma transaction.

- [ ] Write route tests for missing/invalid signatures, duplicate delivery, unknown variants, and a valid `order_created` event.
- [ ] Write service tests proving duplicate orders do not create a second license, `updatesUntil` is purchase time plus 365 days, full refunds set `refunded`, and partial refunds only add an event.
- [ ] Implement signature verification with the original request bytes and `timingSafeEqual`.
- [ ] Persist only an encrypted payload and non-sensitive event metadata; return HTTP 200 after durable Inbox storage.
- [ ] Implement leased processing with bounded attempts, exponential backoff, and a terminal failed state visible to admin queries.
- [ ] Start and stop the worker with the Fastify process; `WORKER_ENABLED=false` disables it in route/unit tests.
- [ ] Run `cd license-server && npm test -- commerceWebhooks.test.ts commerceFulfillment.test.ts` and `npm run build`.
- [ ] Commit Task 2 files with `feat(license): fulfill Lemon Squeezy orders reliably`.

### Task 3: Resend Outbox and one-time recovery delivery

**Files:**
- Create: `license-server/src/services/EmailOutboxService.ts`
- Create: `license-server/src/services/EmailOutboxWorker.ts`
- Create: `license-server/src/services/RecoveryService.ts`
- Create: `license-server/src/routes/emailWebhooks.ts`
- Create: `license-server/src/routes/recoveryPage.ts`
- Modify: `license-server/src/routes/licenses.ts`
- Modify: `license-server/src/app.ts`
- Test: `license-server/tests/emailOutbox.test.ts`
- Test: `license-server/tests/recovery.test.ts`

**Interfaces:**
- `EmailOutboxService.enqueuePurchase(...)` and `.enqueueRecovery(...)` store AES-GCM payloads.
- `EmailOutboxWorker.runOnce(now)` calls Resend `POST /emails` with `Idempotency-Key`.
- `RecoveryService.request(email)` always returns success and queues mail only when an eligible license exists.
- `GET /recover` serves a no-store page that reads `location.hash`, opens `promptstudio://license/recover`, and offers one-time-code copy fallback.

- [ ] Write tests for generic recovery responses, 15-minute token expiry, one-time consumption, cooldown, encrypted outbox payloads, Resend idempotency, retry scheduling, and sensitive payload scrubbing after acceptance.
- [ ] Implement purchase and recovery HTML/text templates with product name, masked email, seat count, support URL, and no tracking pixels.
- [ ] Verify Resend Webhooks using the configured signing secret and persist delivered/delayed/bounced/failed status.
- [ ] Set `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, CSP, and `X-Robots-Tag: noindex` on the recovery page.
- [ ] Run `cd license-server && npm test -- emailOutbox.test.ts recovery.test.ts` and `npm run build`.
- [ ] Commit Task 3 files with `feat(license): add reliable license email and recovery`.

### Task 4: Atomic seat replacement and recovery activation APIs

**Files:**
- Modify: `license-server/src/services/ActivationService.ts`
- Modify: `license-server/src/routes/licenses.ts`
- Test: `license-server/tests/devices.test.ts`
- Create: `license-server/tests/recoveryActivation.test.ts`

**Interfaces:**
- Activate requests accept `replaceActivationId?: string`.
- Recovery activation accepts the recovery token plus the same device identity/proof payload and optional replacement ID.
- Errors use `{ ok:false, error:{ code, message, data? }, requestId }`; `SEAT_LIMIT_EXCEEDED.data` contains only seat counts and safe device summaries.

- [ ] Extend failing tests for safe structured conflict data, replacing only a device from the same license, atomic replacement, replayed proof rejection, and recovery token remaining usable after a seat conflict.
- [ ] Refactor the existing activation transaction so credentials or recovery tokens resolve an authorized license before sharing one activation/replacement path.
- [ ] Consume a recovery token only after certificate issuance succeeds.
- [ ] Ensure replacement marks the old activation `deactivated` with reason `seat_replaced` and records both activation events.
- [ ] Run all license server tests and TypeScript build.
- [ ] Commit Task 4 files with `feat(license): support atomic seat replacement activation`.

### Task 5: macOS API contracts, deep-link routing, and error model

**Files:**
- Modify: `Sources/PromptStudio/License/LicenseAPIClient.swift`
- Modify: `Sources/PromptStudio/License/LicenseManager.swift`
- Modify: `Sources/PromptStudio/License/LicenseState.swift`
- Modify: `Sources/PromptStudio/PromptStudioApp.swift`
- Modify: `Sources/PromptStudio/AppState.swift`
- Modify: `Packaging/Info.plist`

**Interfaces:**
- `LicenseAPIClient.APIError` decodes `code`, localized `message`, optional typed conflict data, and request ID.
- `LicenseManager.activate(email:licenseCode:replacing:)` and `activate(recoveryToken:replacing:)` return the verified certificate or throw a typed conflict.
- `AppState.handleLicenseURL(_:) -> Bool` routes only `promptstudio://license/recover` and opens the license center.

- [ ] Add typed models for seat conflict and transport failures; remove production error text that exposes the server URL or decoder details.
- [ ] Add request timeouts and map offline, timeout, rate limit, 5xx, invalid credentials, revoked, and seat conflict to user-facing categories.
- [ ] Register the `promptstudio` URL scheme and route license URLs before external file handling.
- [ ] Preserve Keychain certificate behavior and verify recovery certificates exactly like code-based activation.
- [ ] Run `swift build` and `swift run PromptStudioCoreUnitTests`.
- [ ] Commit Task 5 files with `feat(license): add recovery and conflict client contracts`.

### Task 6: State-driven license center UI

**Files:**
- Rewrite focused sections: `Sources/PromptStudio/License/ActivationViewModel.swift`
- Rewrite focused sections: `Sources/PromptStudio/License/LicenseSettingsView.swift`
- Modify: `Sources/PromptStudio/Views/Sheets.swift`
- Modify: `Sources/PromptStudio/AppState.swift`

**Interfaces:**
- `LicenseCenterState` cases: `form`, `validating`, `seatConflict`, `recoveryForm`, `recoverySent`, `recovering`, `activated`, `managingDevices`.
- All settings and feature-gate entry points call one `AppState.openLicenseCenter(context:)`.

- [ ] Replace the separate activation and device-management sheets with one 560-point state-driven center; expand to 680 points only for the device list.
- [ ] Implement field validation, paste/Return submit, stable loading layout, inline field errors, retry, recovery cooldown, seat selection, atomic replacement confirmation, success Toast, and full-circle close hover.
- [ ] Reuse one license summary component in the center and Settings; display lifetime ownership, seat use, certificate health, and update entitlement date.
- [ ] Keep local-data policy visible but secondary; remove technical certificate jargon from the primary path.
- [ ] Verify keyboard navigation, VoiceOver labels, disabled states, reduced motion, and no nested Sheet transitions.
- [ ] Run `swift build`, `swift run PromptStudioCoreUnitTests`, and `swift build -c release`.
- [ ] Commit Task 6 files with `feat(license): unify the complete activation experience`.

### Task 7: Integration environment, regression, and experience build

**Files:**
- Modify: `license-server/.env.example`
- Modify: `license-server/README.md`
- Create: `license-server/tests/commercialFlow.integration.test.ts`
- Modify: `docs/PromptStudio_Release_QA_Test_Cases.md` only if it is explicitly staged as part of this task; otherwise create `docs/commercial_license_qa.md`.

**Interfaces:**
- A deterministic local integration fixture creates a signed Lemon Squeezy event, processes Inbox/Outbox with a fake mail transport, and returns a usable test license.
- The Release App uses `PromptStudioLicenseServerURL` override only for local QA; production defaults to `https://license.promptstudio.app`.

- [ ] Add an end-to-end test covering order creation, duplicate webhook, purchase email, normal activation, seat conflict, replacement, recovery, refresh, and full refund.
- [ ] Document Railway services, migration command, DNS/TLS, secret rotation, webhook URLs, product mapping, Resend domain setup, backup, and rollback.
- [ ] Run `npm test`, `npm run build`, `swift test`, `swift run PromptStudioCoreUnitTests`, `swift build -c release`, and `Scripts/build_app.sh release`.
- [ ] Launch the local server fixture and the Release App, verify the four approved license-center states, and keep unrelated user files unstaged.
- [ ] Commit Task 7 files with `test(license): verify the commercial license journey`.

## Completion Gate

- [ ] `git diff --check` passes and every new migration is represented in `schema.prisma`.
- [ ] No source or test contains real Lemon Squeezy, Resend, signing, encryption, or customer secrets.
- [ ] Production build defaults to HTTPS; localhost requires an explicit override.
- [ ] Release App is signed, running, and ready for the user to exercise with the local integration fixture.
