# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**4H-Alarm Robotics Calendar** — A D-language web application for tracking events, shop days, and attendance for the 4H ALARM Robotics team 2079.

## Build & Run Commands

```sh
dub build          # compile the application
dub run            # compile and run
dub test           # run tests
```

Run the server directly after building:
```sh
./alarmcal         # starts HTTP server on 127.0.0.1:8080
```

Add a user via the CLI (admins can also add users, including by email invitation, through the `/addPerson` route)
```sh
./alarmcal cli addUser <name> <email> <password> <membertype> [admin]
# membertype: student | parent | mentor
```

The server reads `alarmcal_config.json5` (JSON5) from the working directory on startup if present. It configures SMTP credentials and the notification poke secret/period, and optionally the team's time zone:
```json5
{
  email: { smtpUrl: "...", username: "...", password: "..." },
  notifications: { alarmcalSecret: "...", periodSeconds: 60 }, // optional block
  timeZone: "US/Eastern", // optional, defaults to US/Eastern
}
```

## Architecture

### Tech Stack
- **Language**: D (LDC/DUB build system)
- **HTTP server**: [serverino](https://github.com/trikko/serverino) — multiprocess HTTP server, routes defined with UDAs
- **Database**: SQLite via `d2sqlite3`, schema and queries via `sqlbuilder`
- **Templates**: `diet-ng` — Pug/Jade-style templates compiled to D at compile time
- **Auth**: Cookie-based sessions (see below) + bcrypt password hashing via `botan`
- **Email**: `postino` SMTP client, dispatched through a background notification thread

### Source Files

| File | Purpose |
|------|---------|
| `source/alarmcal/app.d` | Main entry point, config loading, all HTTP route handlers, session/auth middleware, view models |
| `source/alarmcal/db.d` | DB models (`Person`, `Event`, `Location`, `PersonEvent`, `Session`, `MigrationRecord`), `openDB()`, migration system |
| `source/alarmcal/session.d` | Cookie session lifecycle: token generation/hashing, `startSession`, `validateSession`, `endSession`, `endAllSessions` |
| `source/alarmcal/mail.d` | Builds and sends event/invite/password-reset emails (plain text + diet-rendered HTML) via `postino` |
| `source/alarmcal/notifications.d` | Background notification thread (`spawn`ed in `main`); periodic self-"poke" over HTTP to trigger daily event-reminder emails; queues outgoing email onto the thread |
| `source/alarmcal/router.d` | UDA aliases `getRoute!` and `postRoute!` for route registration |
| `source/alarmcal/formudas.d` | UDAs for form field control: `@noform`, `@password`, `@optional`, `@dbenum!T`, `@timeOnly` |
| `source/alarmcal/dietutils.d` | Template helpers: date/time formatting (`datePrinter`, `timePrinter`) and `parseTime` |
| `views/*.dt` | Diet HTML templates (calendar/list views, admin CRUD forms, auth flows, `mail*.dt` HTML email bodies) |
| `views/form.dt` | Generic compile-time form generator — introspects struct fields via UDAs |

### Key Patterns

**Routing** — Functions annotated with `@endpoint @getRoute!"/path"` or `@endpoint @postRoute!"/path"` are automatically registered as HTTP handlers by serverino. `@route!"/path"` (no verb) handles both GET and POST in one handler, used where a page and its form submission share logic (e.g. `/invitation`, `/forgotpassword`).

**Authentication (cookie sessions)** — `checkSession` in `app.d` runs at `@priority(10)` (before all other endpoints), opens the per-request `db` handle, and validates the `session` cookie via `alarmcal.session.validateSession`. On success it populates `@requestScope` variables `currentUser` and `currentSession`. Session tokens are random 32-byte values; only their SHA-256 hash is stored (`Session.tokenHash`), and each valid request slides `Session.expires` forward by `sessionDuration` (7 days). The cookie itself is set with a much longer `Max-Age` (`cookieMaxAge`, 400 days) since the real timeout is enforced server-side — see the comment above `setSessionCookie` for why the cookie must not be reissued on every request. Unauthenticated requests are redirected to `/login` (with a `?url=` return path) except for the allowlisted public routes: `/login`, `/invitation`, `/performLogin`, `/poke`, `/forgotpassword`, `/performForgotPassword`, and `/assets/*`. Changing a password (self-service or admin-edited) calls `endAllSessions` to invalidate that person's other sessions. Admin-only routes check `currentUser.admin` manually.

**Invitations & password reset** — Admins can create a `Person` with no password via `/addPerson` by checking "send invite"; this generates a random `invitation_id` token, emails a link (`sendInviteEmail`), and blocks normal login for that account until the invite is used (`performLogin` excludes rows with a non-null `invitation_id`). `/invitation?id=...` lets the invitee set a password and clears `invitation_id`. Self-service reset works the same way with `reset_password_id`/`reset_password_time` (20-minute expiry, `passwordResetValidDuration`): `/forgotpassword` requests a reset email, `/forgotpassword?id=...` lets the user set a new password and clears the reset fields.

**Compile-time form handling** — The `extract!T()` function in `app.d` uses `static foreach` over struct fields and UDAs to populate a struct from HTTP form data. `createForm(T)` in `views/form.dt` mirrors this to generate HTML forms. The `@noform` UDA skips fields, `@password` hashes the input with bcrypt (leaving the field untouched if left blank, so edit forms don't clobber existing hashes), `@optional` allows empty values, `@dbenum!Location` renders a `<select>` populated from the DB, and `@timeOnly` treats a `DateTime` field as a single time-of-day input (used for an event's end time, which always shares the start date).

**Database schema** — Defined via sqlbuilder UDAs directly on struct fields: `@primaryKey`, `@autoIncrement`, `@mustReferTo!T(joinName)`, `@refersTo!T(joinName)`. The `Relation` static fields declare join relationships used in queries. Schema is auto-created on first run via `createTableSql!T`.

**Migrations** — `applyMigrations()` in `db.d` tracks applied migrations in a `MigrationRecord` table, verifying each via MD5 hash. Before applying, it backs up the SQLite file. Migrations are append-only entries in the array returned by `applyMigrations()` (currently: add repeat-event `tag_id`, add `Session` table, add `Person.invitation_id`, add `Person` password-reset columns) — never edit an already-applied migration's SQL/logic, since its MD5 is checked against the recorded hash on every startup.

**DateTime handling** — `DateTime` fields in forms are split into two inputs (`_d` for date, `_t` for time) by both `form.dt` and `extract!T()`, unless tagged `@timeOnly`. The diet templates import `alarmcal.dietutils` for rendering helpers. `getTime()` in `app.d` returns the current time in the configured `timeZone`, and should be used instead of `Clock.currTime`/`std.datetime` "now" calls anywhere event/session timing matters.

**Repeating events** — `/performAddEvent` can create a weekly-repeating series: the originating `Event` gets `tag_id` set to its own id, and each generated occurrence shares that `tag_id` (up to 1 year out). Editing or deleting can target "this event only" or "this and subsequent events in the series" (`apply_to`/`delete_scope` params), rewriting/removing rows sharing the `tag_id` with a later `start`.

**Check-in / attendance** — `PersonEvent.attendanceRecorded` is flipped on by `/checkIn`, either for a single `event_id` or for every event a person is RSVP'd to today at a given `location_id` (e.g. scanning one shop-day QR code covers all of that day's events at that location). `askToConfirm` renders a confirmation page (`confirmCheckin.dt`) before committing, to avoid accidental check-ins from a bare link/QR scan.

**Email & notifications** — `mail.d` builds plain-text + diet-rendered HTML emails (RSVP confirmation/cancellation, event edited/removed, invitations, password reset) and hands them to `notifications.dispatchEmail`, which forwards them to a dedicated background thread (`notificationTid`, spawned in `main`) so SMTP calls never block a request-handling worker. That same thread also self-pokes `GET /poke` (protected by the `x-alarmcal-poke-secret` header, configured via `NotificationConfig.alarmcalSecret`) on a timer (`NotificationConfig.periodSeconds`, default 60s); `handlePoke()` in `notifications.d` uses this to detect the start of a new day and email everyone signed up for that day's events. Because serverino runs multiple worker processes, only the main (non-worker) process runs the poke timer/migrations — see `ServerinoProcess.isWorker` checks in `main()` and `notificationThread()`.

**Diet template whitespace** — Trailing spaces at the end of lines in `.dt` files are intentional and meaningful: diet-ng uses them to inject a space between adjacent inline nodes (e.g., `span.attending_check ... &check; ` followed by `| text`). Never strip trailing spaces from diet templates.

### Data Model

- `Person` — team member with `MemberType` (student/parent/mentor), email/password for login, `admin` flag, plus `invitation_id` and `reset_password_id`/`reset_password_time` (all `@noform`, nullable) for the invite and password-reset flows
- `Event` — calendar event with title, start/end `DateTime`, `EventType`, location reference, min/max student/adult counts, and an optional `tag_id` (self-referential) linking occurrences of a repeating series
- `Location` — venue with name and address
- `PersonEvent` — join table linking persons to events, includes `attendanceRecorded` flag for check-in
- `Session` — server-side cookie session: `person_id`, SHA-256 `tokenHash` (raw token is never persisted), `created`/`expires`
- `MigrationRecord` — tracks which schema migrations have been applied, with an MD5 hash per migration for drift detection
