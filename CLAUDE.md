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

Add a user via the CLI (admins can also add users through the `/addPerson` route)
```sh
./alarmcal cli addUser <name> <email> <password> <membertype> [admin]
# membertype: student | parent | mentor
```

## Architecture

### Tech Stack
- **Language**: D (LDC/DUB build system)
- **HTTP server**: [serverino](https://github.com/trikko/serverino) — multiprocess HTTP server, routes defined with UDAs
- **Database**: SQLite via `d2sqlite3`, schema and queries via `sqlbuilder`
- **Templates**: `diet-ng` — Pug/Jade-style templates compiled to D at compile time
- **Auth**: HTTP Basic Auth + bcrypt password hashing via `botan`

### Source Files

| File | Purpose |
|------|---------|
| `source/alarmcal/app.d` | Main entry point, all HTTP route handlers, auth middleware, view models |
| `source/alarmcal/db.d` | DB models (`Person`, `Event`, `Location`, `PersonEvent`), `openDB()`, migration system |
| `source/alarmcal/router.d` | UDA aliases `getRoute!` and `postRoute!` for route registration |
| `source/alarmcal/formudas.d` | UDAs for form field control: `@noform`, `@password`, `@optional`, `@dbenum!T` |
| `source/alarmcal/dietutils.d` | Template helpers: date/time formatting (`datePrinter`, `timePrinter`) and `parseTime` |
| `views/*.dt` | Diet HTML templates |
| `views/form.dt` | Generic compile-time form generator — introspects struct fields via UDAs |

### Key Patterns

**Routing** — Functions annotated with `@endpoint @getRoute!"/path"` or `@endpoint @postRoute!"/path"` are automatically registered as HTTP handlers by serverino.

**Authentication** — `checkAuth` in `app.d` runs at `@priority(10)` (before all other endpoints) and populates `@requestScope` variables `currentUser` and `db`. All routes are protected by HTTP Basic Auth. Admin-only routes check `currentUser.admin` manually.

**Compile-time form handling** — The `extract!T()` function in `app.d` uses `static foreach` over struct fields and UDAs to populate a struct from HTTP form data. `createForm(T)` in `views/form.dt` mirrors this to generate HTML forms. The `@noform` UDA skips fields, `@password` hashes the input with bcrypt, `@optional` allows empty values, and `@dbenum!Location` renders a `<select>` populated from the DB.

**Database schema** — Defined via sqlbuilder UDAs directly on struct fields: `@primaryKey`, `@autoIncrement`, `@mustReferTo!T(joinName)`, `@refersTo!T(joinName)`. The `Relation` static fields declare join relationships used in queries. Schema is auto-created on first run via `createTableSql!T`.

**Migrations** — `applyMigrations()` in `db.d` tracks applied migrations in a `MigrationRecord` table, verifying each via MD5 hash. Before applying, it backs up the SQLite file. The migrations array in `applyMigrations()` is currently empty.

**DateTime handling** — `DateTime` fields in forms are split into two inputs (`_d` for date, `_t` for time) by both `form.dt` and `extract!T()`. The diet templates import `alarmcal.dietutils` for rendering helpers.

### Data Model

- `Person` — team member with `MemberType` (student/parent/mentor), email/password for login, `admin` flag
- `Event` — calendar event with title, start/end `DateTime`, `EventType`, location reference, and min/max student/adult counts
- `Location` — venue with name and address
- `PersonEvent` — join table linking persons to events, includes `attendanceRecorded` flag for check-in
