# Commercial License QA

## Automated gates

- `cd license-server && npm test`
- `cd license-server && npm run build`
- `TEST_DATABASE_URL=... npm test -- commercialFlow.integration.test.ts`
- `swift test`
- `swift run PromptStudioCoreUnitTests`
- `swift build -c release`
- `LICENSE_SIGNING_KEY_ID=... LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL=... Scripts/build_app.sh release`

## User journey

1. Complete a Lemon Squeezy test purchase and confirm duplicate webhook delivery creates one license.
2. Confirm the purchase email contains the masked buyer identity, license code, seat count, update entitlement, and support link.
3. Activate two Macs, then activate a third and replace one old device from the seat conflict screen.
4. Request recovery and open the one-time deep link. Confirm the token expires after 15 minutes and is consumed only after successful activation.
5. Rename and remove a remote device. Removing the current device must return the App to limited mode without touching local library data.
6. Refresh an active certificate, then issue a full refund and confirm the next refresh revokes Pro access.
7. In the Ant Design admin, verify payment, email, recovery, license, activation, and audit records refer to the same journey.

## Release safety

- Production defaults to `https://license.promptstudio.app`.
- Release packaging fails unless a certificate verification public key is injected.
- Lemon Squeezy, Resend, encryption, signing, session, CSRF, and HMAC secrets are stored only in deployment environment variables.
- The admin frontend and `/admin-api` are served on the same HTTPS origin.
- Local prompt and asset content is never sent during activation or recovery.
