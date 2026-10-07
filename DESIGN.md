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
The superadmin, the project owner, moderates by reverting vandalism and blocking users, all via SQL for now; duplicates can't be added.
The superadmin is identified by a hardcoded email address in `app/Main.hs`.
A blocked user cannot sign in, their existing sessions stop working immediately, and the same email cannot sign up again, because the user row is kept.
A code sent before the user was blocked is refused too.
No page ever shows who added or edited a mosque, because that would reveal people's religious affiliation.

## Sign-in
Sign-in uses one-time codes sent by email; there are no passwords.
Signing in for the first time creates the account, so sign-up and sign-in are one flow.
The account is created only once a correct code is entered, so requesting a code for an address creates nothing.
Codes are six digits, expire after 10 minutes, work once, and lock after five wrong attempts.
A new code can be requested at most once a minute per email.
Codes and session tokens are stored only as SHA-256 hashes.
Codes are emailed through Brevo's HTTPS API, from `HILAL_MAIL_FROM` with `BREVO_API_KEY`; production refuses to start without them, and without them, in development, codes are printed to the terminal.
Brevo was chosen for its free tier and because, as an EU company, it is bound by GDPR; it necessarily sees the addresses it delivers to.
An HTTPS API needs no new library, because Hilal already makes HTTPS requests for short links; SMTP would.
If an email can't be sent, the page says so and the code is forgotten, so asking again needn't wait a minute.
The server logs only that a send failed, never the error itself, which could carry the address and the API key.
For demos, `HILAL_DEMO_CODE` (six digits) makes every code that value; the server refuses to start with it when `HILAL_ENV=production`, because anyone knowing it could sign in as anyone.
After signing in, people return to the page they were trying to reach, and that address is checked to be a path on Hilal.

Each email can be sent at most 20 codes in any 24 hours, so nobody can flood an inbox with them.
Once that is reached, the last code sent still works.
Each email can have at most 20 wrong codes entered in any 24 hours; past that, no code is sent or accepted for it until the oldest wrong code is a day old.
That leaves a guesser one chance in 50,000 a day, instead of resetting with every new code.
Someone could use it to stop a person signing in for a day, but existing sessions keep working.
Entering the right code forgets that email's wrong codes; codes sent are never forgotten early, so the cap is a true daily one.
The limits are per email, not per IP address, because Hilal never uses visitors' addresses.
Codes sent and wrong codes are kept in `sent_codes` and `wrong_codes`, as an email and a time only.
Expired codes and sessions, and records of codes older than a day, are deleted whenever someone requests a code, so no background job is needed.

Sessions are a random 256-bit token in a cookie, with the hash stored in the `sessions` table.
They last one year, so people rarely need to sign in again inside the app.
Signing out deletes the session row, so a copied cookie stops working too.
Cookies are `HttpOnly` and `SameSite=Lax`, and `Secure` when `HILAL_ENV=production`.
Every POST route checks that the `Origin` header, when present, matches the `Host` header, as protection against cross-site requests.

## Mosques
A mosque is added from its Google Maps link, because Google Maps already lists almost every mosque, and sharing a link is something everyone knows how to do; nobody in India types latitude and longitude.
Adding has two steps: first the link, then a form with the name filled in, for the address in the form "locality, city", the time zone, and all six timings.
Requiring all six means every mosque is listed and followable from the moment it is added.
The time zone is preselected from the phone's own setting with a few lines of JavaScript, falling back to `Asia/Kolkata`.
Both steps work without JavaScript.

From the link, Hilal takes the place's name, its pin, and Google's id for the place; a link carries nothing else, so the address is typed.
The field accepts the whole text Google Maps shares or a full Google Maps link; a link to a map view, or plain coordinates, has no place in it and is refused.
Short links (`maps.app.goo.gl`) carry nothing themselves, so the server asks Google where they point, without following the link further, and reads that address.
Only `maps.app.goo.gl` is ever contacted, so the field can't be used to make the server fetch other addresses.
The second step carries the place as a link Hilal makes itself, and saving reads and checks it again.
No Google library or API key is used, and nothing else, such as photos or reviews, is taken from Google.
Google may change its links at any time; then nothing can be added until Hilal reads the new form.
A mosque missing from Google Maps must be added there first; tutorials for that will come later.

Against vandalism, such as temples added to mess with Hilal, only places Google Maps names as a mosque can be added.
The name must contain masjid, masjeed, masjed, musjid or mosque, in any case, or "mosque" in an Indian script (Hindi, Urdu, Bengali, Telugu, Tamil, Malayalam, Kannada, Gujarati).
Idgahs, dargahs, madrasas and "palli", which Kerala also uses for churches, are left out on purpose.
This works because the name comes from Google, and renaming a place on Google Maps needs an edit Google reviews.
A real mosque whose Google name lacks these words is refused, with a suggestion to correct its name on Google Maps.
Someone determined could still hand-make a fake Google link; the check stops mistakes and casual vandalism, not fraud, which stays the superadmin's job.

A place can be added only once: Google's id for it is stored, unique, and adding it again points to the mosque already there.
The name is always Google's, never typed, and can't be changed by editing, so a mosque can't be renamed into something else.
A mosque's location never changes either, because mosques are rebuilt where they stand, not moved.
Editing uses the same form as adding, prefilled, but without the link; it changes only the address, time zone, and timings.
The superadmin corrects a wrong name or location with SQL.
There are no photos in v0: Google's photos aren't ours to use, and uploads would need moderation and could show people's faces.

Every addition and change is appended to `edits.log`, one line per change, with the time, user id, and mosque id, but no email; an addition also records Google's id for the place.
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

## Finding mosques
Browsing needs no account; only following does.
The mosque list starts empty, asking for the phone's location or a search, so newcomers aren't faced with every mosque at once.
With a location it shows the 20 nearest mosques, nearest first, with their distance and a map; a search then filters those.
Without one, a search lists matching mosques by name, as before.
Recognising a mosque relies on its locality, distance, and place on the map, because many share a name.

The phone's location is rounded to about 100 m before it leaves the phone, travels only in that page's address, and is never stored or logged.
The map uses MapLibre, served from Hilal itself rather than a CDN, with map tiles from OpenFreeMap, which is free, needs no key, and is built from OpenStreetMap.
Tile requests do tell OpenFreeMap roughly which area is being viewed; that is the one third party involved, and the map credits OpenStreetMap and OpenFreeMap as their terms require.
The map exists only where JavaScript runs; the list works without it.

## The mosque page
The mosque page shows today's date in the mosque's time zone, the Hijri date, the next prayer, all six timings, and when they were last updated.
The next prayer is the first one whose Jamaat minute hasn't passed; after Isha it is tomorrow's Fajr.
On Fridays, Jumu'ah takes Zuhr's place when finding the next prayer, but the Jumu'ah row is always shown.
Next to the next prayer is a countdown to its Jamaat, such as "in 42 min", rounded up to the minute.
The server renders it, so it works without JavaScript; a small script keeps it current, and reloads the page once, a minute after that Jamaat, when the next prayer moves on.
The script runs only on pages with a countdown.
The day of the week is taken in the mosque's time zone.
In the timings table, the next prayer's row is highlighted and framed in gold.
Urdu prayer names sit under the English ones and cells are narrower on phones, so the table fits a 320 px screen; if it still doesn't, it scrolls rather than cutting a column off.

The Hijri date comes from a table of Umm al-Qura month starts, generated by `tools/hijri_table.py` and compiled in, so no outside service is involved.
Local moon sighting in India usually runs a day behind Umm al-Qura, so the page shows both, the earlier first: "19/20 ربیع الثانی 1448", or "29 ذوالحجہ 1447 / 1 محرم 1448" across a month or year, with the month in Urdu.
This suits India and its neighbours; elsewhere it would need revisiting before expanding there.
The table covers 1445 to 1475 AH (2023 to 2053); outside it, no Hijri date is shown.
The Hijri day is taken from the Gregorian date, ignoring that it formally begins at Maghrib.

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
JavaScript is added only where it clearly helps, such as preselecting the time zone, the countdown, finding the phone's location, and the map; HTMX search-as-you-type is shelved for later.
The Android app must work without proprietary Google libraries, such as Google Play Services, so it can be published on F-Droid, which accepts only free software.
Open-source libraries, including AndroidX, are fine.
JSON is used only for the native side: one endpoint listing the signed-in user's followed mosques, and one for a mosque's timings, which the app polls.

## Notifications and sync
A notification is shown at each Azan of each followed mosque, and its text includes that prayer's Jamaat time.
Each followed mosque gets its own notification, even when two share an Azan time.
Few people are expected to follow several mosques; if many do, a primary mosque may be added.
Tapping the notification opens that mosque's page.
There are no separate Jamaat notifications and no per-user notification settings for now.

The notification sounds on the alarm volume, so it plays even when the phone is on silent, as an alarm does; this is what lets the Fajr Azan wake people.
Dismissing the notification stops it, and its sound can be changed or turned off in Android's settings for the "Azan" channel.
The sound comes from the notification channel itself, not a separate player, so no foreground service is needed.
For now it is the phone's default alarm sound.
It will become a recording of the Azan, with a separate Fajr Azan, which has an extra line; the recording must be freely licensed, such as one recorded at a local mosque with the muezzin's written permission, or F-Droid won't accept it.
Android fixes a channel's sound when the channel is created, so a new sound needs a new channel id.

A PWA cannot fire a notification at an exact local time, so alarms are scheduled natively.
The app keeps only the next alarm scheduled, using setAlarmClock, which fires exactly even in Doze mode.
Android shows such an alarm as the phone's next alarm, with an alarm icon in the status bar; that suits Azan, which is much like an alarm.
On Android 14 and later the user must allow exact alarms once; the app asks the first time a sync finds a followed mosque.
Without that permission, the app sets an inexact alarm instead, which may be minutes late, rather than none.
The same permission (`SCHEDULE_EXACT_ALARM`) is used for Play and F-Droid, because Play allows the automatic `USE_EXACT_ALARM` only for alarm-clock and calendar apps.
When an alarm fires, it shows the notifications, schedules the next alarm, and syncs.
Alarms are rescheduled after reboot, time changes, time-zone changes, app updates, and changes to the exact-alarm permission.

Timings are synced by polling; there is no push service (no FCM).
The app syncs whenever a page finishes loading, when the app is left, after every alarm, half an hour before Fajr, and at least once a day.
The pre-Fajr sync exists because there are no alarms between Isha and Fajr, and someone may change Fajr late at night.
The pre-Fajr and daily syncs are one inexact alarm, which needs no permission.
A sync first fetches the followed mosques, then each one's timings, and stores them on the phone, so alarms keep working offline.
A failed sync keeps the stored timings; a 401 means signed out, which clears them and the alarms.

`GET /api/v1/me/mosques` lists the signed-in user's followed mosques by name, with each mosque's id and name; the names are for notification text.
It returns 401 when signed out, and is sent with `Cache-Control: private, no-cache`, because it belongs to one user.
The native side calls it with the WebView's session cookie, read from Android's cookie store, so it needs no sign-in of its own; this is still to be confirmed on a device.

`GET /api/v1/mosques/:id/timings` returns the mosque's time zone and all six timings as 24-hour "HH:MM" text, keyed by stored prayer names.
A mosque without all six timings returns 404, because it is not followable.
The ETag is an FNV-1a hash of the response body, and the response is sent with `Cache-Control: no-cache`, so the app always revalidates and an unchanged mosque costs a tiny 304.

All JSON routes live under `/api/v1`, because installed apps update slowly and can't all be changed at once.
Adding a field is not a breaking change, so the app must ignore fields it doesn't know.
A change that would break installed apps goes under `/api/v2`, and `/api/v1` keeps working until those apps have updated.

## The Android app
The app supports Android 8 and later, which covers nearly every phone in use in India.
It is published on Play, for reach, and on F-Droid, from the same code.
It is a WebView showing Hilal's pages; links to Hilal stay inside the app, and every other link opens in the browser.
The back button goes back through the pages.
The pages' green continues behind the status and navigation bars.
When a page asks for the phone's location, the app asks for precise and approximate location together, so Android 12 and later let the person choose; approximate alone often found nothing, on the emulator and on a real phone.
Either way, the page rounds the location to about 100 m before it leaves the phone.
Backup and transfer to a new phone are turned off: the follows live on the server, and the session cookie must not leave the phone.
Native code uses only Android itself and AndroidX, with no extra libraries; the scheduling logic mirrors `Hilal.Time` and has its own unit tests.
The app is named Hilal, with application id `org.irfanali.hilal`, which can never change once published; the code's own package stays `com.example.hilalalarm`, which nobody sees.
Its icon is the gold crescent on green, drawn as vectors, so no images at different sizes are needed; `icon.svg` is the same drawing, for store listings.
The server's address is in `Config.kt`, one in `src/debug` and one in `src/release`, rather than generated `BuildConfig` code.
Release builds talk to `https://hilal.irfanali.org`.
Debug builds talk to `http://localhost:8080` through `adb reverse tcp:8080 tcp:8080`, by USB or wireless debugging; Android treats localhost as secure, so the WebView allows location there.
Release APKs are signed with a keystore kept beside the project but never committed; it is backed up elsewhere, because without it no update can ever be installed over the app.
Debug builds also have an "Alarm test" screen, which fires an alarm every 15 minutes and shows a history of alarms and syncs kept on the phone.

## Backend
The backend is Haskell with Scotty, SQLite through `sqlite-simple`, `lucid2` for HTML, and the `time` library.
Time zones use `tz` with `tzdata`, which bundles the time zone database in the binary.
Secure randomness and hashing use `crypton`, and cookies use `cookie`.
Scotty was chosen over Servant because the app is small and heavy on HTML, forms, cookies, and headers, which are simpler in Scotty.
Each request opens its own SQLite connection and closes it when done; for SQLite this is cheap and avoids shared state.
Every connection enables foreign keys, WAL mode, and a busy timeout.
Settings that differ between development, tests, and production live in a `Config` value passed to `app`.

Until launch, the schema lives in `schema.sql`, using `CREATE TABLE IF NOT EXISTS`, and runs at every startup.
After any schema change, delete hilal.db and let it be recreated empty; mosques are then added through Hilal itself, as on the server.
At launch, schema.sql becomes the first numbered migration, and every later change is a new append-only migration tracked with PRAGMA user_version.
Never edit a migration after it has been deployed.

Modules:

- `Hilal.Types`: domain types and their conversions to and from the database.
- `Hilal.DB`: opening connections.
- `Hilal.Migrate`: creating the schema.
- `Hilal.Query`: all SQL queries.
- `Hilal.Time`: time zones and next-prayer logic.
- `Hilal.Hijri`: Hijri dates, from the generated table in `Hilal.HijriTable`.
- `Hilal.Location`: reading places from Google Maps links, following short links, checking that a place is named as a mosque, and distances.
- `Hilal.Auth`: codes, tokens, hashing, cookies, sign-in limits, and request checks.
- `Hilal.Edit`: the mosque form, its validation, and edit-log lines.
- `Hilal.Email`: sending sign-in codes through Brevo.
- `Hilal.Assets`: the embedded stylesheet and its fingerprinted URL.
- `Hilal.JSON`: JSON responses for the native app.
- `Hilal.Views`: HTML pages.
- `Hilal.App`: routes and configuration.

## Deployment
Hilal runs at `hilal.irfanali.org`, on a Fedora VPS that also serves other sites, behind Nginx as a reverse proxy.
It is deployed the same way as those sites: a folder in the owner's home, synced from the development machine, run by systemd under the owner's own user.
Keeping it to a folder, one program, one SQLite file, systemd, and Nginx means there is no container, CI, or database server to maintain.

`make deploy` does everything from the development machine, over SSH:

1. rsync copies the folder to the server, skipping `.git/` and everything `.gitignore` lists except `hilal.env`, with `--delete --delete-after`;
2. the server builds Hilal with ghcup, so it links against Fedora's own libraries, and installs the program as `hilal` in the folder;
3. it copies `deploy/hilal.service` to `/etc/systemd/system/` and restarts Hilal.

Each step runs only if the one before succeeded, so a failed build never replaces the running program.
Replacing the program file doesn't stop the running one; the restart switches to it.
`--delete-after` deletes only once the new `.gitignore` has arrived, because the server decides what to delete from its own copy; deleting earlier removed `hilal.env` the first time it was added to `.gitignore`.
`make vendor` downloads Tailwind, daisyUI, MapLibre and the fonts on the server, once and whenever `install_vendor.sh` changes, because they are built for each machine.
`make status` and `make log` show the service's state and output.
The server's SSH host and folder are in `config.mk`, which git ignores, because the repository is public.

What exists only on the server is listed in `.gitignore`, so rsync neither sends it nor deletes it: the built `hilal`, `hilal.db` and `edits.log`, and the downloaded `vendor/`.
The local database is never copied over by a deploy.
Hilal never seeds its database, on the server or locally.
Until launch, a schema change means deleting `hilal.db` on the server too, losing its data.

`deploy/` holds the two files the server needs:

- `hilal.service`, the systemd unit, which runs `hilal` from the folder, reads `hilal.env`, restarts Hilal if it stops, and lets it write only its own folder;
- `hilal.nginx.conf`, installed once by hand as `/etc/nginx/conf.d/hilal.conf`, because certbot then adds HTTPS to the installed copy, and copying it again would remove that.

Hilal reads these environment variables:

- `HILAL_ENV=production` makes cookies `Secure` and makes Hilal refuse to start with a demo code or without the two below;
- `BREVO_API_KEY` and `HILAL_MAIL_FROM` send sign-in codes by email;
- `HILAL_DEMO_CODE`, never set on the server, makes every code that value, for offline demos.

The first three are in `hilal.env`, readable only by its owner, kept on the development machine and sent by `make deploy`, and never committed.
Without these variables, as when running locally with `cabal run`, codes are printed to the terminal instead.

Nginx terminates HTTPS, with a certificate from Let's Encrypt through certbot, and compresses responses; Hilal itself speaks plain HTTP on port 8080.
Hilal listens on every interface, so the firewall must keep port 8080 closed to the outside, leaving the proxy as the only way in.
The proxy must pass the original `Host` header through, because the cross-site check compares it with `Origin`; otherwise every POST is refused.
The proxy's access log is turned off, because the nearby list carries the phone's location in its address.
Its error log is kept at the `crit` level for the same reason, because lower levels record the request line when Hilal is down.
Hilal reads no forwarded-address headers, because it never uses visitors' IP addresses.

## Frontend
Styling is Tailwind CSS v4 with daisyUI v5, built with Tailwind's standalone executable, so no Node is needed.
Exact versions are pinned in `install_vendor.sh`, which also fetches MapLibre; `build_css.sh` generates `static/app.gen.css` from `static/app.css`.
MapLibre is pinned to version 5, the last with a single browser file; version 6 is split into several modules.
Tailwind class names in Haskell are always complete literal strings, never assembled at runtime, so the scanner can find them.
The look is traditional: deep green (#1F4D3A) and classic gold (#D4AF37) on cream, like a mosque's notice board.
Its themes are `hilal` and `hilal-dark` in `static/app.css`, following the phone's light or dark setting; in dark mode the surfaces turn deep green and gold carries the emphasis.
Every page opens with a green band holding its heading, patterned with faint gold Persian star-and-cross tiles, as on Iranian mosques; the pattern is a small SVG drawn by `tools/pattern.py`, not an image file.
A bottom bar of tabs (My mosques, Nearby, Account), in the same green and gold, makes the pages feel like an app inside the Android shell.
The next prayer gets a gold-framed card with its Jamaat time in large type.
Clarity matters more than polish: large times, obvious structure, and large tap targets.
Times are displayed in 12-hour format with AM/PM, as on mosque notice boards; storage stays 24-hour.

Fixed labels also appear in Urdu, as on mosque boards in India: prayer names (فجر, ظہر, …), the Prayer, Azan, and Jamaat headings (نماز, اذان, جماعت), and Hijri months.
They use the Urdu spellings rather than the Arabic ones, which suits India; nothing users type is ever in Urdu.
Latin text is set in Inter and Urdu in Noto Sans Arabic, whose upright Naskh style reads better on a phone than Nastaliq.
Both fonts are served from Hilal itself, never from Google Fonts, and the Urdu font is cut down to just the letters Hilal uses, about 22 KB.
So a new Urdu word must also be added to `URDU_TEXT` in `install_vendor.sh`, which needs `pip install fonttools brotli` for the cutting.
Page titles include the mosque name, so shared links preview well in chat apps.

The generated stylesheet, the two fonts, and MapLibre's two files are embedded in the binary and served at `/static/HASH/NAME`.
HASH is an FNV-1a fingerprint of the contents, so the URL changes exactly when the file changes.
They are cached for a year; any HASH is accepted, so pages opened before a deploy keep working.
MapLibre is about 1 MB, 280 KB compressed; Hilal doesn't compress responses itself, so the proxy in front of it should.
HTML pages are sent with `Cache-Control: no-cache`, so they always reference the current stylesheet.
Deployment is a single binary with no asset folder.

## Testing
Tests use `hspec` and `hspec-wai`.
Every query has a test, because the compiler cannot check SQL against the Haskell types.
Shared test data lives in `seed` in `test/Tests.hs`, and every test gets a fresh copy of it.
Query tests use an in-memory database; route tests use a temporary file, because each request opens its own connection.
Route tests that need sign-in capture codes and edit-log lines through the test configuration.
Tests never contact Google: the short-link resolver is part of the configuration, and tests replace it.
Test data is fictional or uses well-known public mosques, never personal details.

## Privacy
Hilal is open source and private by design.
It keeps no request logs, never stores where someone is, and never shows who added or edited a mosque.
The proxy in front of it must keep no logs that would undo this; see Deployment.
What a person follows is stored, because following needs it, and is visible to no one else.

## Not decided or not built yet
- Testing the Android app on real phones, especially Xiaomi, Oppo, Vivo, Realme and Samsung, whose battery management may delay alarms.
- A freely licensed Azan recording, with a separate Fajr Azan, to replace the default alarm sound.
- Each mosque's own recorded Azan, which would need moderation, the muezzin's consent, and storage.
- Tutorials on adding a mosque to Google Maps, for mosques missing there.
- Maghrib following sunset plus an offset, using the stored coordinates.
- Following straight from the map, without opening the mosque's page.
- A verification mark: green when a mosque is followed and nobody has reported its timings as wrong, a warning when someone has.
- Search-as-you-type with HTMX, using `hx-select` on the existing page.
- A primary mosque, if many people follow several mosques.
- Mosque admins, if community editing stops working at scale.
- Account deletion, a privacy page, and privacy obligations, since followed mosques reveal religious affiliation; Play requires a privacy policy.
- Backing up `hilal.db` daily, with SQLite's `.backup`, since copying the file while Hilal runs can give an inconsistent copy; and rotating `edits.log`.
- Keeping the previous `hilal` program on the server, for a quick rollback.
- Publishing on Play and F-Droid.
