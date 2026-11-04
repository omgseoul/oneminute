# Persistent administrator login

Administrator PIN sessions previously expired 12 hours after login with no renewal.
Both login RPCs now store PostgreSQL `infinity`, while existing Android releases
receive the parseable ISO compatibility value `9999-12-31T23:59:59Z`. Server token
lookup, active account, property, PIN lockout and service access checks remain in
place. No function/table grants are added. No password/PIN is saved client-side.

The migration upgrades only currently valid active-owner sessions and their
matching native push registrations. Expired/revoked sessions are never restored.
`end_app_session`, account disabling/deletion and existing operator revocation
continue to stop access; push routing also checks the server session each time.

Staff behavior is unchanged: 20 hours anchored to original login, token replaced
on another login to the same shift, and explicit logout after checkout report.

Client session checks preserve storage on transport or incomplete-response
failures; they do not grant offline access. Delayed checks cannot erase a newer
login or restore a session after logout. Account logout also revokes the app
session instead of only deleting local storage.

Run from repository root with the pinned PGlite dependency from the attendance
test package available through NODE_PATH:

```sh
node tests/session-persistence/database.cjs
node tests/session-persistence/client.cjs
java tests/session-persistence/NativeExpiry.java
```

The database test uses isolated synthetic accounts, existing authentication
definitions in baseline.sql, and the real migration and native push functions.
No live guest/staff messages or real PINs are used. Native expiry test verifies
the Java parser contract; it is not a physical handset push delivery test.
