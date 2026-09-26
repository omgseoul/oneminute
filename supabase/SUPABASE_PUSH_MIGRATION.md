# Supabase notification migration

Status (2026-09-26): app data/auth use Supabase. Android 0.11.0 removes legacy Firebase Auth/Firestore. FCM remains the Android notification transport. SQL 033 and `dispatch-notification` are deployed; the send-only FCM connection passed validation and `PUSH_DELIVERY_ENABLED=true` is installed. `notification-config.js` now uses `provider: "supabase"`; production Pages deployment was verified. Telegram/Make cutover remains with the owner. Device display still needs an on-device check.

## Owner-operated Make cutover
The owner will edit Make; do not edit or sign into Make on their behalf.

In the existing Telegram `!!` route, edit its existing HTTP request module (do not add a second sender):

- Method: `POST`.
- URL: `https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/telegram`.
- Preserve the existing `x-webhook-secret` header and value. The same secret is already installed on Supabase; do not put it in chat or screenshots.
- Content type: `application/json`.
- Keep `property_id` as the current numeric branch management number, not the database UUID.
- Keep `text` mapped to the original Telegram message text, including the `!!` prefix.
- Add or retain `update_id`, mapped to Telegram's Update ID. Use the real mapped value, not a fixed number or the current timestamp. An alternative accepted shape is `message.chat.id` plus `message.message_id` and `message.text` from the original update.
- Prefer JSON field mapping/Create JSON so quotes and line breaks in messages are escaped correctly; do not insert raw message text into a hand-built JSON string.

Save the scenario with only one active HTTP sender. A genuine `!!` message should be stored once as urgent and return HTTP 200 with `ok: true`. `!!테스트` only tests the alert path and deliberately does not save an inbox message. `!!정지` stops the alert. A response with `external_id_required` means the Update ID mapping is missing; `invalid_property` means the management number needs checking. Keep the previous HTTP URL for rollback until phone receipt and inbox storage are verified.

No existing Firebase functions or historical data have been deleted. Older Android installations must update to 0.11.0 to remove their Firebase Auth/Firestore dependencies.

## Apply
1. Run additive `migrations/033_supabase_push_delivery.sql`.
2. Deploy `dispatch-notification` with `verify_jwt=false`. The handler validates custom app-session tokens through a service-only RPC; webhook routes require independent secrets.
3. Configure Edge secrets securely (never in git/chat):
   - `FCM_SERVICE_ACCOUNT`: JSON key for a dedicated service account in `guesthouse-manager-ajh`, restricted to Firebase Cloud Messaging send permissions.
   - `TELEGRAM_URGENT_SECRET`: shared secret used by the existing Telegram/Make caller.
   - `PUSH_ADMIN_SECRET`: separate random secret for transport validation only.
   - `PUSH_DELIVERY_ENABLED=true` only after validation.
   Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
4. POST `{}` to `/functions/v1/dispatch-notification/validate` with `x-webhook-secret: PUSH_ADMIN_SECRET`. Expected `{ok:true,validated:true}`. This uses FCM validate_only and sends no notification.
5. Switch `notification-config.js` provider to `supabase`. Update the existing Telegram automation HTTP target to `/functions/v1/dispatch-notification/telegram`, preserving its webhook secret header and supplying a stable update_id (or Telegram chat/message IDs) and property_id.
6. Verify on a consenting test device: foreground/background urgent alert, inbox storage, normal notification, logout suppression, staff-to-owner ordinary message, cross-property recipient. Keep existing Firebase functions until verified.

## Rollback
Change only provider to `firebase` and restore the Telegram HTTP URL to its previous Firebase function. Do not auto-fallback after a timeout: delivery may already have happened. Keep Supabase data and receipt tables intact; no deletion required. Android 0.11.0 is compatible with the existing Firebase push payloads.

## Delivery guarantees
Messages are stored before push dispatch. Successful per-recipient sends are deduplicated; active leases prevent concurrent retries. Failed requests can retry. Ambiguous timeouts retain a 90-second lease; a later retry can still duplicate transport delivery. No automatic retry worker or exactly-once guarantee is claimed. FCM acceptance does not prove device display; OS permissions/battery/network remain relevant.

## Verification
`node --test supabase/tests/push-handler.test.mjs` (mock network, actual WebCrypto signing).
`NODE_PATH=<pglite node_modules> node supabase/tests/attendance-login-warnings.test.cjs` (disposable PostgreSQL; existing attendance plus delivery lease/security checks).
GitHub Actions builds Android APK; no real employee notification is sent by these tests.
