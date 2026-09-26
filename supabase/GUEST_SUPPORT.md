# QR guest support module

Status: implementation and isolated tests complete; install migration and Edge functions before enabling UI in production.

## Deploy
1. Apply `migrations/034_guest_support.sql` to the existing project. It is rerunnable and adds isolated tables/private Storage bucket; it does not modify the attendance or property message tables.
2. Deploy `guest-support` and the updated `dispatch-notification` functions with `--no-verify-jwt`. Application authorization is enforced by server-only SQL RPCs using the existing custom session token; guests use a random room capability. No new public database grants are introduced.
3. Reuse existing `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `PUSH_ADMIN_SECRET`, `FCM_SERVICE_ACCOUNT` and `PUSH_DELIVERY_ENABLED=true` secrets. Never put these in a web asset or QR URL.
4. Publish web files and Android 0.12.0 (code 19). Existing 0.11.1 cannot open guest room push routes or apply the new volume behavior.
5. Property → QR 현장 고객 대응: add guides, enable the portal/chat, configure each employee/owner's notification branches/hours, save. All notification preferences start OFF so cleaners and unrelated users are not opted in without a choice.

## Behavior
- QR contains the portal UUID only. Guest capability is generated with `crypto.randomUUID`, stored on that guest browser and hashed in DB. It never enters URLs.
- Name/dates/optional room are self-declared, **not proof of a reservation**. Guests cannot enumerate rooms or access employee identities. Booking verification is a separate future integration.
- Guide uploads: JPEG/PNG/WebP/PDF, max 4 MiB. Chat: images only. Browser normalizes images to JPEG, <=1600 px; gateway checks signature and SQL ownership; Storage is private with 15-minute signed URLs.
- New room produces the exact normal alert “현장 게스트와의 대화가 시작되었습니다.” Subsequent guest messages produce urgent alerts. Every event is stored, with per-recipient delivery leases, bounded retries while a room is open and a five-minute delivery lifetime. This does not guarantee delivery when the phone is offline or Android blocks background execution.
- Cross-branch access follows existing approved directed Property shares with `messages` permission. Receiving alerts is a separate per-account opt-in. Active work sessions / valid owner sessions only; recipient identity and session expiry are checked on device.
- Preferences use home-property timezone. Empty start/end or equal values mean all day. Overnight ranges attribute after-midnight hours to the previous selected weekday. Payload expires at the end of the permitted window as well as the five-minute event limit.
- First staff reply claims an unassigned room. Others may reply and are attributed internally; explicit takeover records an internal system event. Guests only see “직원”.
- Active room uses incremental 2-second polling, a 100-message cursor and visibility/network backoff. This is not a WebSocket implementation. Staff room list polls every five seconds; rooms load in cursor-based pages of 50 with an older-conversation button.
- Guest must keep/reopen the browser tab to see replies. Browser background push and translation/AI are not part of this version.
- Urgent Android alarm uses STREAM_ALARM at device maximum, then restores the saved original value on acknowledgement/service teardown. Vibration-only test stays silent. OS DND restrictions, fixed-volume devices and killed processes cannot be guaranteed away.

## Disable / remove
Turn portal activation OFF to stop guest entry and sending, or disable Chat to keep guides only. Existing staff history remains readable. Disable individual alert checkboxes to stop those recipients. No need to delete history or roll back existing attendance/messages. To remove the UI, remove the isolated menu links/new pages; leave tables/Storage until an explicit retention decision. Do not delete the shared dispatch function or FCM transport.

## Validation
`NODE_PATH=<pglite node_modules> node supabase/tests/guest-support.test.cjs`
`node --test supabase/tests/guest-support-handler.test.mjs supabase/tests/push-handler.test.mjs`
`NODE_PATH=<pglite node_modules> node supabase/tests/attendance-login-warnings.test.cjs`

Production acceptance after installation: use a test property and opted-in test employee; verify guest entry, photo exchange, owner alias, cross-branch responder, disabled/time-window notifications, background full-screen urgent notification and acknowledgement volume restoration on the target Android device. Do not test-send messages to real employees without explicit authorization.

## Message hub and manual retention (035)
- `messages.html`: one hub with guest/staff/alerts tabs. Old guest-chats URLs redirect here.
- Account cards in staff-management own notification preferences; QR settings only own guest portal content.
- Platform operator center reports UTF-8 body bytes and private object metadata sizes (not database physical/billing size).
- 3/6/9/12-month cleanup snapshots selected record IDs, expires after 10 minutes, requires exact property-name confirmation, and audits each job. No automatic cleanup runs.
- Text and photo categories are independent. QR guide assets are excluded. Internal messages currently have no photo attachment column; their photo category is shown as unavailable/0.
- Database deletion detaches selected old photos and persists their Storage API deletion queue; failures can be resumed from OMG WORKS. Storage rows are never directly deleted via SQL.
- Deploy 035 migration and updated guest-support Edge function before publishing UI. No APK replacement required for these web screens.
