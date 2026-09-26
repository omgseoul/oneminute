# Supabase notification migration

Status: app data/auth already use Supabase. Android 0.11.0 removes legacy Firebase Auth/Firestore. FCM remains the Android notification transport. `notification-config.js` intentionally keeps `provider: "firebase"` until transport validation succeeds.

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
