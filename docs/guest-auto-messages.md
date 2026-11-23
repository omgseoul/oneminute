# Guest automatic messages

Guest message → Auto → select one property → + 자동메시지 추가. Settings use an accordion list; completing the editor opens the title dialog. The inbox retains its existing multi-property filter, while automatic-message settings allow exactly one authorized property and never All.

Each rule stores a required common template and optional nationality-specific versions. Buttons insert `{{이름}}`, `{{체크인}}`, `{{체크아웃}}`, `{{비밀번호}}`, `{{객실}}` at the caret. Country uses Beds24 country2/country, never inferred names. Unknown/missing countries and unconfigured language versions use common. The password is the uniquely assigned room booking's `LOCK_PIN`; missing/conflicting codes wait, preserving leading zeroes. Raw provider data and names are not modified.

Reservation rules use bookingTime (instant or N × 24 hours later). Check-in offsets use property-local date and configured clock time (default 09:00). The existing authenticated Beds24 minute worker claims up to four due jobs per invocation. New and confirmed bookings in the existing Beds24 cache are eligible; webhooks already hydrate that cache. Before sending, the worker re-fetches booking status, country, room assignment and PIN, then rechecks the rule revision and pause state. No rule is installed/enabled by deployment.

Rules apply to future due times after activation. Missed execution can catch up within 24 hours, but old due times before activation/resumption are not backfilled. Each rule/booking pair can send once; ambiguous network outcomes are marked uncertain and never automatically resent. The property-scoped history displays results and booking IDs without storing rendered PINs in this feature's logs. Existing Make/Beds24 automations are independent and should be coordinated by the operator.

Schema: `supabase/setup/guest_auto_messages.sql` and matching migration. Private RLS-enabled tables; public RPC wrappers execute only as service_role. Configuration RPC validates a live owner session and both messages/property-settings permissions for shared properties. No provider delete or inventory mutation is introduced.

Validation: `tests/online/auto-messages-database.cjs`, `auto-messages-edge.mjs`, `auto-messages-ui.cjs` (320/360/412px), and existing inbox/edge regression tests. Network sends use fixtures in tests; no guest receives test messages.
