# Attendance basis and NFC checks

Run from repository root:

```sh
npm ci --prefix tests/attendance-nfc
npx --prefix tests/attendance-nfc playwright install chromium
npm test --prefix tests/attendance-nfc
```

Database tests run entirely in isolated PGlite with synthetic data, including anonymous transport roles and explicit OMS session authorization. They never create production users or sessions. UI tests stub the server and native NFC bridge. Layout tests use the actual owner-settings markup and styles at 320, 360, 412, and 720px. Android compilation and existing emulator regressions run in the repository APK workflow. Physical NFC capture needs a compatible phone and a stable-UID tag; emulator tests do not verify radio hardware.

The two public RPCs deliberately follow OMS's existing PIN/session-token authentication contract: hashed, unexpired owner/staff session, active account, and branch/share permission checks run before accessing data. Underlying tables retain RLS and no additional direct table grants. The advisory about callable security-definer RPCs is expected for that contract; the private normalization helper has no anonymous execution grant. Settings never accept a staff identity or an entry timestamp from the client.

NFC reads are foreground-only on the native app home/report pages, or explicitly requested on the settings page. They read UID bytes without writing the tag. Read callbacks are correlated to a request, discarded on navigation/cancel, and disabled while the activity is paused. Manual values use the same uppercase hex representation, accepting spaces/colons/hyphens. No tag IDs are written to application logs. A static UID is an identifier, not cryptographic proximity proof.

First NFC entry is retained on the work-session row, not reset by subsequent taps. A new work session has no entry. NFC alone does not submit an attendance report. Confirmed or NFC-entered shifts survive re-login across midnight. The existing 20-hour lifetime remains anchored to the original login, so positive/negative report offsets cannot extend or prematurely end a shift. An unreported, untagged previous-day login still starts a new shift. Existing attendance is untouched when settings change; report resubmission does not recalculate clock-in.

Production migration applied as `20261024105646_attendance_nfc_report_offset`. Post-deploy checks confirm RLS, invalid-token rejection, zero offsets and empty tag lists for all pre-existing properties. No owner's selected attendance basis was changed.

An additional legacy `supabase/tests/report-client.test.cjs` run stops at the pre-existing “PIN login does not flash a hard-coded property name” assertion; the unchanged baseline reproduces that failure. New settings/worker integration tests and existing `tests/attendance-time.cjs` pass.

Follow-up migration `20261024111120_preserve_attendance_shift_across_midnight` preserves confirmed shift identity across midnight and anchors expiry to the original login. Isolated tests cover negative offsets crossing a work date, an NFC entry before reporting, and starting a fresh shift after the 20-hour limit.

## Compact worker progress and optional NFC submission

The home page uses the original connected-dot progress bar. NFC settings show `현장도착(NFC)`; first-login and report-offset settings show `로그인`. Employee identity moves to the working-list heading, with a yellow pre-report dot and green post-report dot. No worker NFC cards are mounted.

Opening check-in without an NFC entry shows the shared OMS dialog: `확인` dismisses it; `무시하고 메뉴보기` opens the report. The server uses an existing NFC entry, or its own report timestamp when no entry exists. Report-mode offsets do not affect this fallback. Later scans cannot rewrite a submitted untagged shift. Existing authorization, row locking, idempotence and overnight shift boundaries remain in force.

The check-in success flow shows only `출근완료`, then returns home on confirmation. Watch-test payload flags and instructions are removed; the save RPC also strips legacy clients' flags.

`progress.cjs` exercises real home CSS at 320/360/412/520px, first-stage labels, state changes, both dialog buttons, and the real report/session submit and failure flow with mocked transports. The database fixture covers untagged fallback, spoofed client time, disabled watch flags, tagged shifts, and -10/0/+10 report offsets. No production attendance fixtures are created. Physical NFC radio operation remains an on-device check; the native bridge is unchanged and no APK rebuild is required.
