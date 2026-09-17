# Supabase connection preview

This folder previews the reviewed attendance app from commit `50b7c1e9c8f84155d5ff6f248b3feb118269f8b9`.
It adds a visible notice and separates browser storage from the future main app.
Report submission controls are disabled and the preview helper cannot save or send reports.
It connects to the real OMG Works Supabase project: successful login creates
or resumes real attendance, but report saving and all webhook/notification transport are disabled.
Live Make webhook URLs have been removed from this preview.
No dedicated test users or test database have been created.

First owner check: open `login.html`, choose a staff member and shift, enter
the new PIN privately, and confirm that the matching report opens with the
correct staff member and login time. Do not submit a report during this first
check. Do not paste PINs, saved session tokens or populated SQL into a review.

Only `supabase-test/` is added to the production branch by this preview PR.
Existing app files at the repository root are unchanged. Native owner menus,
alerts and missions are not covered by this browser check.

2026-09-17: the real `list_login_employees` API returned HTTP 200 and the four
expected staff. The local source passed 68 PostgreSQL and 26 mocked browser
checks before this preview copy. A successful live login has not been verified.
