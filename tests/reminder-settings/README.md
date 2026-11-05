# Reminder schedule checks

Run from the repository root with `@electric-sql/pglite` 0.3.14 and `playwright` 1.51.1 available to Node:

```sh
node tests/reminder-settings/database.cjs
node tests/reminder-settings/mobile.cjs
```

The database test uses an isolated in-memory PostgreSQL database and a mocked push transport; it never sends real notifications. The browser test serves the actual owner settings HTML/CSS locally and mocks only RPC/session initialization. Install Playwright Chromium and a Korean font for visual checks.

Behavior:
- Existing schedules default to fixed time with no overdue repetition.
- `trigger: checkin` uses a fresh `checkin_report_at` (completed arrival report), not login or NFC arrival. Existing one-minute cron delivers within approximately one minute.
- Fixed-time overdue reminders run daily at the chosen time until completion/ending. Check-in overdue reminders run once per worker per local day after a new report.
- Workers receive only their own eligible, unfinished tasks; owners receive one check-in reminder per item/rule/day, even when several workers report.
- Multiple overdue rules at the same trigger/time merge into one daily reminder. Different times remain independent.
- Calendar reminders support check-in but reject overdue repetition. Owner-only calendar items remain private to owners.
- Newly enabled check-in rules ignore earlier reports. The server owns activation timestamps and preserves them on unchanged saves.
- The existing fixed-time delivery key remains valid, preventing a deployment replay.

Tests cover validation, atomic saving, limits, legacy settings, branch isolation, timezone, completion modes, duplicate suppression, same-day activation, calendar privacy, private worker permissions, and compact 320–720px layout / interaction / save payloads.
