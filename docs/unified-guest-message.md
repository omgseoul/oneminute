# Unified guest inbox — 2026-11-14

The home screen uses the approved compact eight-button arrangement. Online booking conversations and the existing onsite QR rooms now open in Guest message. QR rooms use a red 현장QR tag and an additional reservation-status option, retain their original IDs and read cursors, and open the existing full conversation for media and room controls. The former staff messenger guest tab redirects to this page.

Administrator and employee sessions share the list UI. The initial employee row keeps attendance reporting. Access is limited to the home property and message-sharing permissions; connection credentials, billing and administrator settings remain protected. A server aggregate provides guest and messenger unread counts independently of the paginated inbox.

Ordinary online/QR arrival cards are excluded from the bot feed and its unread totals. Recipient records, full-screen notification delivery, AI support handoffs and other bot notices are retained. Deep links to the former online thread route remain compatible.

Automatic online popup translation uses the configured target and exclusions and the existing metered cache. Translation precedes `원문:` in web and native notification bodies. Translation preparation waits at most four seconds for a dispatch batch before falling back to the original; a pending cache result can refresh the web popup on subsequent polling. Native notifications already delivered in the original are not re-sent. No APK change is required.

Deployment: apply `supabase/setup/beds24_unified_guest_messages.sql`, then `supabase/setup/beds24_popup_translation.sql`; deploy `beds24` and `dispatch-notification` with their existing custom authentication (verify_jwt=false); publish the web assets. Existing guest history is not moved or deleted.

Validation: database tenancy/session/worker restrictions, QR pagination/filter/read/reply, idempotent send, bot feed totals and preserved recipients, translation exclusions and safe payloads, 320/360/412 px browser layouts, eight-card home bootstrap, legacy notification queue and online regression suites. No real guest messages are sent by the tests.
