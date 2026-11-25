# Staff scheduled messages

Staff chat only. Long-press Send to choose a future time or the recipient employee’s next completed check-in report. The reservation list allows the sender to edit or cancel pending/failed messages.

The private database queue stores the payload and sender identity, never a login token. The worker runs every minute, rechecks active sender, property and recipient permissions, and uses row locks and a unique delivery identifier to prevent duplicate messages. Group delivery uses current membership. Login or NFC alone never triggers delivery. An existing completed report is excluded when arming a reservation. Failed delivery stays in the sender’s reservation list with a reason.

Validation: database fixture (23 checks), web scheduling and Calendar update-button tests, native scheduling instrumentation, APK replacement install with preserved private app data, persistent signing certificate, production cron execution and security-advisor comparison. All test recipients were synthetic; no test messages were sent to real staff.

Release: OMS 0.19.1 (1266), Calendar 1.3.0 (8). Calendar 1.3.0 is the one-time installation required to add the native updater bridge; subsequent versions can be installed via the title’s Update button. Android retains its installation permission and final confirmation screens.

## Compact chat controls (approved option 1)

The composer uses a smaller priority pill and square photo glyph. A calendar with a red dot appears immediately left of the emoji control only while the sender has pending or failed reservations in this conversation. Removing the final reservation hides the calendar and restores input space. Long-pressing Send opens a small anchored two-action menu; tapping the calendar opens a compact preview list. Select a list item to change its message, delivery condition, or cancel it. Normal Send remains immediate.

Web layout checks cover 320, 360 and 412 pixel widths, reserved text space, square photo icon, menu anchoring and hidden empty-calendar state. Native instrumentation exercises the actual composer, check-in scheduling, list/edit flow, calendar visibility and regular Send, and records screenshots of the two popups.
