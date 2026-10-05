# Hilal: Design

This file records the decisions behind Hilal and the reasons for them.
Read it before changing anything fundamental, and update it when a decision changes.

## What is Hilal?
Hilal is an open-source Android app that notifies people of Azan and Jamaat times at the mosques they follow.
The distinguishing feature is that timings are the mosque's own, as announced at the mosque, not calculated.
Timings are public: anyone can see any mosque's timings on the web without signing in.
Nothing is paywalled.

## Users and roles
Hilal is community-maintained, like a semi-protected wiki.
Anyone can browse mosques and timings without signing in.
Signing in is required to add a mosque, edit a mosque, or follow one.
Every signed-in user can add and edit any mosque; there are no mosque admins.
Mosque admins may be added later, only if the community model stops working at scale.
The superadmin, the project owner, moderates by deleting duplicates, reverting vandalism, and blocking users, all via SQL for now.
The superadmin is identified by a hardcoded email address in `app/Main.hs`.
A blocked user cannot sign in, their existing sessions stop working immediately, and the same email cannot sign up again, because the user row is kept.
No page ever shows who added or edited a mosque, because that would reveal people's religious affiliation.

## Sign-in
Sign-in uses one-time codes sent by email; there are no passwords.
Signing in for the first time creates the account, so sign-up and sign-in are one flow.
Codes are six digits, expire after 10 minutes, work once, and lock after five wrong attempts.
A new code can be requested at most once a minute per email.
Codes and session tokens are stored only as SHA-256 hashes.
Sending email is not built yet; in development, codes are printed to the terminal.
After signing in, people return to the page they were trying to reach, and that address is checked to be a path on Hilal.

Sessions are a random 256-bit token in a cookie, with the hash stored in the `sessions` table.
They last one year, so people rarely need to sign in again inside the app.
Signing out deletes the session row, so a copied cookie stops working too.
Cookies are `HttpOnly` and `SameSite=Lax`, and `Secure` when `HILAL_ENV=production`.
Every POST route checks that the `Origin` header, when present, matches the `Host` header, as protection against cross-site requests.

## Mosques
Adding a mosque requires a name, an address in the form "locality, city", a time zone, and all six timings.
Requiring all six means every mosque is listed and followable from the moment it is added.
The time zone is preselected from the phone's own setting with a few lines of JavaScript, falling back to `Asia/Kolkata`.
Coordinates are optional for now; a location picker comes later.
Duplicates are tolerated; the superadmin deletes them.
Editing uses the same form as adding, prefilled.

Every addition and change is appended to `edits.log`, one line per change, with the time, user id, and mosque id, but no email.
The log is plain text on purpose, so it can be searched with `grep`; it is not stored in SQL.

## Timings model
A mosque has one set of current timings: an Azan time and a Jamaat time for each of Fajr, Zuhr, Asr, Maghrib, Isha, and Jumu'ah.
There is no timetable, no history, and no "effective from" date.
When timings change, they should be updated after that day's prayer has passed, so the change applies from the next day.
The editor notes each prayer that hasn't happened yet today, because a change to it would apply to today.
Jamaat may not be earlier than Azan for the same prayer.
Only timings that actually change get a new `updated_at`, so "Updated" on the mosque page stays honest.
Maghrib is entered manually for now; later it may follow sunset plus an offset, which is one reason to store coordinates.

Times are local wall-clock times at the mosque, stored as "HH:MM" text, together with the mosque's IANA time zone (e.g. "Asia/Kolkata").
They are never stored as UTC, so a time like 20:00 stays 20:00 across daylight-saving changes.
Conversion to an exact moment happens in the mosque's time zone, not the phone's.

## The mosque page
The mosque page shows today's date in the mosque's time zone, the next prayer, all six timings, and when they were last updated.
The next prayer is the first one whose Jamaat minute hasn't passed; after Isha it is tomorrow's Fajr.
On Fridays, Jumu'ah takes Zuhr's place when finding the next prayer, but the Jumu'ah row is always shown.
The day of the week is taken in the mosque's time zone.

## Following
Following a mosque requires signing in, and only listed mosques can be followed.
There is no limit on how many mosques someone follows.
When signed in, the home page is "My mosques", showing each followed mosque with its next prayer.
When signed out, the home page redirects to the mosque list.

## Architecture
The UI is server-rendered HTML shown inside a thin native Android shell (a WebView).
This means UI changes reach every user on deploy, without an app-store release.
The native shell exists for what the web cannot do reliably: exact alarms.
If the WebView approach becomes difficult, the fallback is to make the home screen native first, then more screens if needed.

HTML is built with plain links and forms first, so every page works without JavaScript.
JavaScript is added only where it clearly helps, such as preselecting the time zone; HTMX search-as-you-type is shelved for later.
JSON is used only for the native side: one endpoint for a mosque's timings, which the app polls.

## Notifications and sync
A PWA cannot fire a notification at an exact local time, so alarms are scheduled natively.
The app keeps only the next alarm scheduled, using setAlarmClock, which fires exactly even in Doze mode.
When an alarm fires, it shows the notification, syncs timings, and schedules the next alarm.
Alarms are rescheduled after reboot, time changes, and time-zone changes.

Timings are synced by polling; there is no push service (no FCM).
The app syncs when opened, after every alarm, shortly before Fajr, and once a day as a fallback.
The pre-Fajr sync exists because there are no alarms between Isha and Fajr, and someone may change Fajr late at night.
The endpoint is `GET /api/mosques/:id/timings`, returning the mosque's time zone and all six timings as 24-hour "HH:MM" text, keyed by stored prayer names.
A mosque without all six timings returns 404, because it is not followable.
The ETag is an FNV-1a hash of the response body, and the response is sent with `Cache-Control: no-cache`, so the app always revalidates and an unchanged mosque costs a tiny 304.
Custom Azan sound is not supported for now; it would come with native notification channels later.

## Backend
The backend is Haskell with Scotty, SQLite through `sqlite-simple`, `lucid2` for HTML, and the `time` library.
Time zones use `tz` with `tzdata`, which bundles the time zone database in the binary.
Secure randomness and hashing use `crypton`, and cookies use `cookie`.
Scotty was chosen over Servant because the app is small and heavy on HTML, forms, cookies, and headers, which are simpler in Scotty.
Each request opens its own SQLite connection and closes it when done; for SQLite this is cheap and avoids shared state.
Every connection enables foreign keys, WAL mode, and a busy timeout.
Settings that differ between development, tests, and production live in a `Config` value passed to `app`.

Until launch, the schema lives in `schema.sql`, using `CREATE TABLE IF NOT EXISTS`, and runs at every startup.
After any schema change, delete hilal.db and let it be recreated; `seed_db.sh` does this and loads test data.
At launch, schema.sql becomes the first numbered migration, and every later change is a new append-only migration tracked with PRAGMA user_version.
Never edit a migration after it has been deployed.

Modules:

- `Hilal.Types`: domain types and their conversions to and from the database.
- `Hilal.DB`: opening connections.
- `Hilal.Migrate`: creating the schema.
- `Hilal.Query`: all SQL queries.
- `Hilal.Time`: time zones and next-prayer logic.
- `Hilal.Auth`: codes, tokens, hashing, cookies, and request checks.
- `Hilal.Edit`: the mosque form, its validation, and edit-log lines.
- `Hilal.Assets`: the embedded stylesheet and its fingerprinted URL.
- `Hilal.JSON`: JSON responses for the native app.
- `Hilal.Views`: HTML pages.
- `Hilal.App`: routes and configuration.

## Frontend
Styling is Tailwind CSS v4 with daisyUI v5, built with Tailwind's standalone executable, so no Node is needed.
Exact versions are pinned in `install_css.sh`; `build_css.sh` generates `static/app.gen.css` from `static/app.css`.
Tailwind class names in Haskell are always complete literal strings, never assembled at runtime, so the scanner can find them.
daisyUI's default light and dark themes are used for now, following the phone's setting; a custom theme comes with a later styling pass.
Clarity matters more than polish: large times, obvious structure, and large tap targets.
Times are displayed in 12-hour format with AM/PM, as on mosque notice boards; storage stays 24-hour.
Page titles include the mosque name, so shared links preview well in chat apps.

The generated stylesheet is embedded in the binary and served at `/static/HASH/app.css`.
HASH is an FNV-1a fingerprint of the contents, so the URL changes exactly when the CSS changes.
The stylesheet is cached for a year; any HASH is accepted, so pages opened before a deploy keep their styling.
HTML pages are sent with `Cache-Control: no-cache`, so they always reference the current stylesheet.
Deployment is a single binary with no asset folder.

## Testing
Tests use `hspec` and `hspec-wai`.
Every query has a test, because the compiler cannot check SQL against the Haskell types.
Shared test data lives in `seed` in `test/Tests.hs`, and every test gets a fresh copy of it.
Query tests use an in-memory database; route tests use a temporary file, because each request opens its own connection.
Route tests that need sign-in capture codes and edit-log lines through the test configuration.
Test data is fictional or uses well-known public mosques, never personal details.

## Not decided or not built yet
- Sending email; codes are printed to the terminal until just before demos.
- Coordinates: a location picker, pasting a Google Maps link, "near me", and perhaps a map.
- The Android shell, and a JSON endpoint listing a user's followed mosques for it.
- A verification mark: green when a mosque is followed and nobody has reported its timings as wrong, a warning when someone has.
- Search-as-you-type with HTMX, using `hx-select` on the existing page.
- A styling pass and a custom theme.
- A live countdown to the next prayer.
- A Hijri date, which depends on local moon sighting and needs care.
- Mosque admins, if community editing stops working at scale.
- Account deletion, a privacy page, and privacy obligations, since followed mosques reveal religious affiliation.
- Versioning the JSON API before the first app release.
- Rotating and backing up `edits.log`.
- Distribution without Google Play Services, e.g. F-Droid.
