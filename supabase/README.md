# Supabase migration status

## Step 1: database foundation only

Run `migrations/001_initial_schema.sql` in the SQL Editor of the new
`omg-works-app` project. It creates five RLS-enabled tables, revokes direct
client privileges, and seeds the existing business, property and four staff
names. It does not set PINs, create login/report RPCs, import historical
records, or change the deployed application.

The earlier unexecuted combined migration was narrowed to this foundation
step after review. Do not use its historical version to enable authentication.

The user ran step 1 in Supabase and reported that the follow-up query returned
all five tables with row security enabled. This confirms the foundation only.

## Step 2: initial staff PINs

`setup/002_register_employee_pins.example.sql` is a manual setup template,
not an automatic migration. The owner replaces its four placeholders with
6-8 digit PINs directly in the Supabase SQL Editor. Never commit or request
the filled-in query. The script uses bcrypt with cost 10, discovers the
installed pgcrypto schema, limits updates to the seeded property and staff,
and aborts if an employee is missing, duplicated or already has a PIN. It
returns only employee names and registration booleans, not hashes or PINs.
PINs entered in SQL Editor may remain in the owner's saved query/history;
do not share that query or its screenshot. App access is still closed.

The user supplied a result showing all four staff with `pin_ready = true`,
confirming step 2. PIN values were visible in that screenshot. Treat those
values as temporary test credentials; rotate them before granting any client
execution privileges. Do not reproduce or commit the screenshot values.

## Step 3: install session/report functions, keep API access closed

`migrations/003_staff_sessions.sql` creates seven client-facing functions but
explicitly revokes their execution from PUBLIC, anon and authenticated. The
final result must show seven function names with `access_locked = true`.
Private helpers are placed in `omg_private` with no client schema access.

The functions implement property-scoped PIN verification, five-attempt
lockout for 15 minutes, rotating bearer tokens with a 20-hour maximum session
age, server timestamps, device logout without a fake clock-out, and one
report per session/type. Unfinished prior workdays become `needs_review`
with their unknown clock-out time preserved. Replacing the partial index
does not delete attendance rows. Make acknowledgement records HTTP acceptance,
not proof that Telegram ultimately received a message.

This script was executed twice in a local in-memory PostgreSQL environment
(PGlite 0.5.8 with pgcrypto). `tests/session-workflow.test.cjs` passed 68 checks
covering table/function privileges, null/wrong PINs, lockout, token rotation,
expiry, logout, disabled staff, tenant isolation, replay-safe reporting,
missing checkouts, recovery of saved reports, PIN rotation, atomic combined
installation and preservation of data on reinstall. This is not a
hosted Supabase or multi-connection concurrency test. No production data or
Make webhooks were touched during these local tests. Hosted installation
was subsequently confirmed by the owner's combined-script result below.

Run the local test with PGlite installed in a separate development directory:
`NODE_PATH=/path/to/node_modules node supabase/tests/session-workflow.test.cjs`.

## Combined installation: owner confirmed on 2026-09-17

Use `setup/005_install_and_activate.example.sql` after the confirmed steps 1
and 2. It combines migration 003 and setup 004 in one transaction, so those
two files do not need to be run separately. Replace `NEW_PIN_1` through
`NEW_PIN_4` with different 6-8 digit PINs, each different from that employee's
old PIN. Run the whole query. Invalid or unchanged PINs roll back the entire
installation. The script preserves attendance records, expires old tokens,
and grants only the seven public functions to anon/authenticated. Direct
table access remains closed. The final result should contain seven rows
with `api_ready = true`. Do not share filled queries or PIN screenshots.

The combined file was tested locally with synthetic credentials. On
2026-09-17 the owner supplied a hosted SQL Editor result with all seven
expected function names and `api_ready = true`. This confirms function
installation and execution grants. It does not prove a successful live
login or report submission. Do not rerun the PIN rotation unnecessarily.

## Local app integration and remaining deployment checks

The local app now validates sessions with the server on entry and expires
them on device logout. Staff login routes to the matching report. Login time
is the attendance timestamp, independent of report submission time. Reports
are saved before Make delivery; retries and reloads recover the saved payload.
A local receipt prevents resending a known successful Make request when only
the database acknowledgement failed. An ambiguous network failure can still
cause downstream duplication: Make deduplication using the stable `report_id`
has not been configured. HTTP acceptance is not Telegram delivery proof.

`tests/report-client.test.cjs` passed 26 browser workflow checks with JSDOM
and mocked transports, including report recovery, retry handling, timing,
session validation and logout. No live Make requests were made. Run with
`NODE_PATH=/path/to/node_modules node supabase/tests/report-client.test.cjs`.

Before production deployment, test the real login/report flow in a preview.
Native owner/inbox/mission routes still require a separate
compatibility check. Native device login and emergency notifications still
use Firebase; those features are outside this attendance migration. No APK
or complete Firebase replacement has been validated. A successful database
setup is not a completed application migration.

No Supabase changes have been executed by the assistant. The user confirmed
steps 1 and 2 and the combined installation through their SQL Editor. A
read-only GitHub check on 2026-09-17 confirmed `main` remains at
`50f10d93b31a40cbba5d164c135f73de71d723d3`. Remote upload of the draft branch
previously stopped during automatic review; the reason was not available.
Obtain confirmation before retrying that blocked upload. Production rollout
also remains unapproved; do not merge or change live Pages during draft review.
