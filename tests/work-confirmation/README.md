# Attendance continuation

The server schedules an explicit confirmation every 12 hours from the clock-in report, independently of the payroll clock-in basis. Each request has a 10-minute server deadline. Expiry ends working presence, leaves checkout/report timestamps NULL, and retains authentication. No response from a dialog dismissal, message read receipt, or network failure extends work.

Run from the repository root with `NODE_PATH` pointing to the dependencies in `tests/attendance-nfc/node_modules`:

```
node tests/work-confirmation/database.cjs
node tests/work-confirmation/browser.cjs
node tests/session-persistence/client.cjs
node tests/attendance-time.cjs
```

The database test uses isolated PGlite fixtures, the actual migration, anonymous RPC privileges, deadline boundaries, repeated confirmations, different employees, normal checkout races, token transfer, and a 37-hour missing-checkout correction followed by owner approval. The browser test uses Chromium at 360 × 740 and covers explicit response, failure/retry, expiry, login retention, and owner exclusion. Android CI runs `WorkConfirmationProbe` against the actual Activity with a debug-only synthetic API seam; it never sends a live attendance response.

Rollout: publish web and Android 0.18.2 before applying the migration. The migration extends only currently valid reported shifts, never revoked or expired tokens. Active legacy shifts already over 12 hours receive a fresh 10-minute window. The private cron runs every minute; foreground clients also evaluate the deadline against server time. The new missing-checkout correction API retains the existing owner approval workflow and accepts an explicit checkout date for shifts spanning multiple days.
