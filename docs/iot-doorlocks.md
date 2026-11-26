# OMS TTLock integration

## Setup

1. Operations center → TTLock: enter the **EU** Open Platform approved Client ID/Secret. Credentials go to Supabase Vault. Saving is not a live credential validation; the first property account connection validates them.
2. Property → IOT 도어락 연동: connect the ordinary TTLock administrator account. Its password and mandated MD5 wire hash are never persisted. Only access/refresh tokens are stored in Vault.
3. Map each OMS room to a Beds24 room type **and unit** and one TTLock lock. Optional common entrances receive the same booking PIN. Cross-property lock assignment is rejected.
4. Choose phone/OTA reference/Beds24 ID suffix or random digits, length 4–9, creation day/time, and validity times. Missing/invalid/duplicate suffixes fall back to random.
5. Stop Beds24 TTLock automatic issuance for these rooms, then turn OMS issuance ON. Enabling requires the existing owner secondary password. Reservations are refreshed before enabling.

Existing hardware must support remote custom passcodes through a gateway or WiFi (`addType=2`). No Bluetooth SDK calls or physical unlock operations are exposed. Each property starts OFF.

## Existing Lock info and recovery

- Read the live Beds24 booking with `includeInfoItems=true` before **any TTLock request**.
- Any existing `LOCK_PIN` (including blank or duplicate items) blocks a new issue. Keep it untouched and issue a terminal bot notice including guest, booking reference, room and stay dates: `기존 Lock info가 있어 비밀번호를 생성하지 못했습니다. 기존 Lock info를 삭제한 뒤 다시 시도해 주십시오.`
- Only a journaled OMS write-intent with the exact same PIN can be reconciled as a prior successful write after a lost response. A different value is never overwritten.
- Register and read back the custom PIN on every selected lock before adding a new `LOCK_PIN`. Recheck live booking identity/dates and existing info immediately before the write. Beds24 offers no atomic compare-and-set; a final read detects concurrent external changes. Do not run both issuers together.
- Unique job/property/booking, expiring leases, persisted planned locks and names `OMS {job UUID}` prevent duplicate additions after response loss. Retry is for that failed reservation only. Ordinary errors retry up to three attempts; existing info fails immediately.
- Cancellation, room/date changes and expiry maintain/delete **only OMS-owned** codes identified by the job name and tracked lock set. External codes are never removed. OFF pauses all issuance/maintenance; validity already stored on the lock still expires normally.
- No PIN or API token is returned in processing history or bot notifications. The guest PIN remains available through the established live Beds24 booking-detail path.

## Scheduling and counts

Cron wakes the worker each minute. Enabled properties consume existing webhook/synchronized reservation data; every claimed job is revalidated against live Beds24. Initial activation refreshes the current/upcoming booking window. Late/same-day bookings already past the configured issue time are eligible on the next worker cycle. One job per property may run at once.

Every attempted TTLock request reserves one count atomically before it is sent; failed/timed-out requests are conservatively counted too. All properties share a 30,000-call **OMS budget**, keyed to Client ID and UTC calendar month. This is not a TTLock billing API or authoritative provider balance: calls made outside OMS and provider month boundaries can differ. At the OMS limit, calls stop. The operations usage tab shows consumed/limit/remaining and property breakdown.

## Deployment and validation

- Migration: `supabase/migrations/20261126034723_iot_doorlocks.sql` (same content as `supabase/setup/iot_doorlocks.sql`). Uses existing Vault, pg_cron, pg_net, worker secret and bot dispatch.
- Edge function: `iot-locks`, `verify_jwt=false` because it separately verifies the worker secret, platform Supabase session/admin role, or owner custom session/property permissions. Service-only RPCs never accept direct browser calls.
- Existing secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `PUSH_ADMIN_SECRET`; Vault `oms_guest_ai_worker_secret`. No app credentials in source/env/frontend.
- `NODE_PATH=tests/attendance-nfc/node_modules node tests/iot-locks/database.cjs`
- `node --test tests/iot-locks/worker.test.mjs`
- `NODE_PATH=tests/attendance-nfc/node_modules node tests/iot-locks/ui.cjs`

Live account authentication and physical-door validation require the operator-entered Client ID/Secret, property account and an enabled mapped room. Tests use simulated provider responses, not a production guest reservation. Opening logs / web-checkin custom guest PIN selection are separate follow-up capabilities, not enabled here.
