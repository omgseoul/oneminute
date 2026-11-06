# Employee IDs and plan limits

Run from repository root with Node and `@electric-sql/pglite`, `playwright`, and `jsdom` installed:

```
node tests/employee-login/database.cjs
node tests/employee-login/mobile.cjs
node tests/reminder-settings/database.cjs
node tests/reminder-settings/mobile.cjs
node tests/operations-center-ui.cjs
```

Database tests execute the new migrations in isolated Postgres WASM. Only pre-existing PIN hashing/session creation and external notice infrastructure are stubbed; no real worker receives notifications. Tests cover name migration, property-scoped case-insensitive IDs, same-name accounts, atomic duplicate rejection, shared-property saving, quota growth/reactivation, existing rooms above the limit, platform policy round trips, and API privileges.

Browser tests run the actual pages with fixture RPCs at 320/390/720px, verify typed login and unchanged administrator selection, themed duplicate dialogs, automatic IDs, salary mapping for same-name workers, a single reminder heading, and stable operator tabs. Reminder tests cover 5/4/3/2/1/0-day windows, retry/overlap deduplication, legacy same-day delivery, overdue completion behavior, and immediate registration notifications independent of preferences.

Limits default to 10 per property. Existing rooms/accounts are retained when above a lowered limit; edits and reductions are allowed, additions/reactivations are blocked. Older account save clients that omit `login_id` preserve the saved ID. Existing work/admin sessions and PINs are not reset.
