# Scheduling Phase C — Meetings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add meetings — schedule/reschedule/cancel/add-attendee/remove-attendee, plus a Calendar page that lists upcoming meetings with each attendee's local time — as plain mutable rows written through tempo's audit seam.

**Architecture:** A new `meeting` concept mirrors the `location` concept (CQRS: `command.gleam` writes, `view.gleam` reads, `http.gleam`, `sql/*.sql`), split across `server/`, `shared/`, `client/`. Rows are plain and mutable (`meeting` / `meeting_detail` / `meeting_attendee`); a reschedule is an in-place `UPDATE`. Because the `audit_id` FK is only available inside `repository.write`, every meeting write is produced as a `fact.Fact` variant and threaded through the existing dispatch → `event_log` seam. The composite `ScheduleMeeting` create form is bespoke client UI (the frozen scalar `OpForm` cannot hold a repeated attendee list); the four granular edits reuse the flat op-form engine.

**Tech Stack:** Gleam (server=Erlang target via `pog`/Wisp/Squirrel; shared+client=JavaScript target via Lustre), PostgreSQL, Playwright.

**Spec:** `docs/superpowers/specs/2026-07-05-scheduling-phase-c-meetings-design.md`. **Template concept:** `location` (server+shared+client). **Design doc:** `docs/2026-07-04-scheduling-calendar-design.md` (Layer C).

## Global Constraints

- **DB port:** export `TEMPO_DB_PORT=5435` for `bin/migrate`, `bin/test`, `bin/serve`, `bin/e2e`, `bin/squirrel`, `gleam test`. The 5434 default is wedged.
- **migrate before squirrel:** `TEMPO_DB_PORT=5435 bin/migrate` then `TEMPO_DB_PORT=5435 bin/squirrel` (squirrel introspects the live DB).
- **Clean-build after adding a union variant:** `cd server && gleam clean && gleam build` (and `cd shared`/`cd client` `gleam build`) after adding a variant to `Command`, `Fact`, `CommandKey`, `OpKind`, `Route`, `Page`, `Msg` — incremental builds mask inexhaustive `case`.
- **Seed "now" is 2026-06-15.** Gleam/server tests run on the base seed (`bin/test`, DB `tempo_test`); e2e runs on the demo seed (`bin/e2e`, DB `tempo_e2e`, rebuilds the client bundle first).
- **Test output:** never pipe a test/build runner through `head`/`tail`/`grep` in the same command; redirect to a file (`… 2>&1 | tee /tmp/x.log`) then inspect.
- **Gleam style:** `let assert Ok(...)` for Result unwrapping; `assert expr == expected` in tests (no gleeunit `should`); `todo` for stubs; NO inline comments (only terse `////` module / `///` public-fn doc comments); descriptive names (no `x_typename`); enumerate statuses as a type rather than a bare string where it is a domain value (`Attendance`).
- **Naming/period conventions** (temporal facts): a change is a new row; but meetings are the plain-mutable exception — `meeting_detail`/`meeting_attendee` use ordinary `PRIMARY KEY` and in-place `UPDATE`/`DELETE`, keeping only the `audit_id` column.
- **Nullable Squirrel params:** a nullable INSERT-value param types as non-null — pass `option.unwrap(x, "")` + `nullif($n, '')` for text, `option.unwrap(x, 0)` + `nullif($n, 0)` for a nullable id.

---

## File Structure

**New files:**
- `server/priv/migrations/20260705120000_meeting.sql` — the three tables.
- `server/src/tempo/server/meeting/sql/*.sql` + generated `server/src/tempo/server/meeting/sql.gleam` — write + read queries.
- `server/src/tempo/server/meeting/command.gleam` — routes a `MeetingCommand` to `Recorded` facts.
- `server/src/tempo/server/meeting/view.gleam` — the upcoming-meetings read (folds meetings + attendees).
- `server/src/tempo/server/meeting/http.gleam` — `GET /api/meetings?as_of=`.
- `shared/src/shared/meeting/command.gleam` — `MeetingCommand` union + `Attendance` + codecs.
- `shared/src/shared/meeting/view.gleam` — `MeetingRecord` / `AttendeeRecord` + codecs.
- `client/src/client/page/meetings.gleam` — the Calendar page (MVU).
- `server/test/meeting_test.gleam` — dispatch-level integration tests.
- `client/test/meeting_command_test.gleam` — client command-builder tests.
- `e2e/meetings.spec.js` — Playwright flow.

**Modified (exhaustive wiring):** `shared/command.gleam`, `shared/access.gleam`, `shared/access/policy.gleam`, `server/.../fact.gleam`, `server/.../repository.gleam`, `server/.../auth.gleam`, `server/.../command.gleam`, `server/.../web/router.gleam`, `client/.../ui.gleam`, `client/.../route.gleam`, `client/.../app.gleam`, `client/.../icons.gleam`, `server/priv/seed/base_seed.sql`, `server/priv/seed/rbac_seed.sql`, `server/test/codec_test.gleam`.

---

## Data model reference (used across tasks)

`meeting_at` is a `tstzrange` of absolute instants. The organizer supplies **date + start (HH:MM) + duration (minutes) + timezone**; SQL composes the range:

```sql
tstzrange(
  (($date::text || ' ' || $starts_at::text)::timestamp AT TIME ZONE $timezone),
  (($date::text || ' ' || $starts_at::text)::timestamp AT TIME ZONE $timezone)
    + ($duration_minutes::text || ' minutes')::interval,
  '[)')
```

UTC offset (minutes east) of a zone `tz` at an instant `t`, DST-correct — the instant-aware form of the Phase A date-based offset:

```sql
((extract(epoch from (t AT TIME ZONE tz)) - extract(epoch from (t AT TIME ZONE 'UTC'))) / 60)::int
```

Instants cross the wire as ISO-8601 UTC strings so the client formats per-zone with the offsets:
`to_char(lower(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`.

---

### Task 1: Schema migration + meeting SQL + Squirrel regen

**Files:**
- Create: `server/priv/migrations/20260705120000_meeting.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_create.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_detail_insert.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_reschedule.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_cancel.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_attendee_insert.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_attendee_delete.sql`
- Create: `server/src/tempo/server/meeting/sql/timezone_valid.sql`
- Create: `server/src/tempo/server/meeting/sql/meetings_upcoming.sql`
- Create: `server/src/tempo/server/meeting/sql/meeting_attendees_asof.sql`
- Generated: `server/src/tempo/server/meeting/sql.gleam`

**Interfaces:**
- Produces (generated `meeting/sql.gleam` functions, consumed by Tasks 2 & 4): `meeting_create(db)`, `meeting_detail_insert(db, meeting_id, date, starts_at, duration_minutes, timezone, title, location, client_id, project_id, audit_id)`, `meeting_reschedule(db, meeting_id, date, starts_at, duration_minutes, timezone, audit_id)`, `meeting_cancel(db, meeting_id, audit_id)`, `meeting_attendee_insert(db, meeting_id, engineer_id, attendance)`, `meeting_attendee_delete(db, meeting_id, engineer_id)`, `timezone_valid(db, timezone)`, `meetings_upcoming(db, as_of)`, `meeting_attendees_asof(db, meeting_ids, as_of)`. (Exact arg order follows `$1..$N` in each file.)

- [ ] **Step 1: Write the migration.**

Create `server/priv/migrations/20260705120000_meeting.sql`:

```sql
-- 20260705120000_meeting.sql — meetings for the scheduling subsystem (Phase C). Unlike
-- every other domain table these rows are plain and mutable: a reschedule is an in-place
-- UPDATE of meeting_at, a cancel flips status. Only audit_id links each change to
-- event_log (who/when); no bitemporal period is kept. meeting is an identity anchor so a
-- future detail dimension can be added without touching it.
CREATE TABLE meeting (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY);

CREATE TABLE meeting_detail (
  meeting_id bigint    NOT NULL PRIMARY KEY REFERENCES meeting (id),
  meeting_at tstzrange NOT NULL,
  meeting_tz text      NOT NULL,
  title      text      NOT NULL,
  location   text,
  status     text      NOT NULL DEFAULT 'scheduled',
  client_id  bigint    REFERENCES client (id),
  project_id bigint    REFERENCES project (id),
  audit_id   bigint    NOT NULL REFERENCES event_log (id)
);
CREATE INDEX meeting_detail_audit_id_idx ON meeting_detail (audit_id);

CREATE TABLE meeting_attendee (
  meeting_id  bigint NOT NULL REFERENCES meeting (id) ON DELETE CASCADE,
  engineer_id bigint NOT NULL REFERENCES engineer (id),
  attendance  text   NOT NULL DEFAULT 'required',
  PRIMARY KEY (meeting_id, engineer_id)
);
```

- [ ] **Step 2: Write the write-side SQL sources.**

`server/src/tempo/server/meeting/sql/meeting_create.sql`:
```sql
-- meeting_create.sql — mint a new meeting identity row, returning its id.
INSERT INTO meeting DEFAULT VALUES RETURNING id;
```

`server/src/tempo/server/meeting/sql/meeting_detail_insert.sql`:
```sql
-- meeting_detail_insert.sql — insert a meeting's detail. $1 meeting_id, $2 date,
-- $3 starts_at (HH:MM), $4 duration_minutes, $5 timezone, $6 title, $7 location ('' = null),
-- $8 client_id (0 = null), $9 project_id (0 = null), $10 audit_id.
INSERT INTO meeting_detail
  (meeting_id, meeting_at, meeting_tz, title, location, status, client_id, project_id, audit_id)
VALUES (
  $1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $5, $6, nullif($7, ''), 'scheduled', nullif($8, 0), nullif($9, 0), $10);
```

`server/src/tempo/server/meeting/sql/meeting_reschedule.sql`:
```sql
-- meeting_reschedule.sql — move a meeting in place. $1 meeting_id, $2 date, $3 starts_at,
-- $4 duration_minutes, $5 timezone, $6 audit_id. RETURNING gates a missing meeting.
UPDATE meeting_detail SET
  meeting_at = tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  meeting_tz = $5,
  audit_id   = $6
WHERE meeting_id = $1
RETURNING meeting_id;
```

`server/src/tempo/server/meeting/sql/meeting_cancel.sql`:
```sql
-- meeting_cancel.sql — mark a meeting cancelled. $1 meeting_id, $2 audit_id.
UPDATE meeting_detail SET status = 'cancelled', audit_id = $2
WHERE meeting_id = $1
RETURNING meeting_id;
```

`server/src/tempo/server/meeting/sql/meeting_attendee_insert.sql`:
```sql
-- meeting_attendee_insert.sql — add or re-mark an attendee. $1 meeting_id, $2 engineer_id,
-- $3 attendance (required|optional).
INSERT INTO meeting_attendee (meeting_id, engineer_id, attendance)
VALUES ($1, $2, $3)
ON CONFLICT (meeting_id, engineer_id) DO UPDATE SET attendance = EXCLUDED.attendance;
```

`server/src/tempo/server/meeting/sql/meeting_attendee_delete.sql`:
```sql
-- meeting_attendee_delete.sql — drop an attendee. $1 meeting_id, $2 engineer_id.
DELETE FROM meeting_attendee WHERE meeting_id = $1 AND engineer_id = $2;
```

`server/src/tempo/server/meeting/sql/timezone_valid.sql`:
```sql
-- timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1) AS valid;
```

- [ ] **Step 3: Write the read-side SQL sources.**

`server/src/tempo/server/meeting/sql/meetings_upcoming.sql`:
```sql
-- meetings_upcoming.sql — scheduled meetings ending on/after $1, earliest first. Times
-- cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is meeting_tz's UTC
-- offset (minutes east) at the meeting start. $1 = as_of date.
SELECT m.id AS meeting_id,
       d.title AS title,
       d.meeting_tz AS meeting_tz,
       to_char(lower(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE d.meeting_tz))
         - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int AS canonical_offset_minutes,
       d.location AS location,
       d.client_id AS client_id,
       d.project_id AS project_id
FROM meeting_detail d
JOIN meeting m ON m.id = d.meeting_id
WHERE d.status = 'scheduled'
  AND upper(d.meeting_at) >= $1::date
ORDER BY lower(d.meeting_at), m.id;
```

`server/src/tempo/server/meeting/sql/meeting_attendees_asof.sql`:
```sql
-- meeting_attendees_asof.sql — attendees of the scheduled meetings ending on/after $1,
-- each with name and their location-tz-as-of-$1 local UTC offset at the meeting start.
-- Unlocated attendees have NULL timezone/offset. $1 = as_of date.
SELECT a.meeting_id AS meeting_id,
       a.engineer_id AS engineer_id,
       ec.name AS name,
       a.attendance AS attendance,
       loc.timezone AS timezone,
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int
       END AS local_offset_minutes
FROM meeting_attendee a
JOIN meeting_detail d ON d.meeting_id = a.meeting_id AND d.status = 'scheduled'
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id AND loc.located_during @> $1::date
WHERE upper(d.meeting_at) >= $1::date
ORDER BY a.meeting_id, ec.name;
```

- [ ] **Step 4: Apply the migration and regenerate typed SQL.**

Run:
```bash
TEMPO_DB_PORT=5435 bin/migrate 2>&1 | tee /tmp/mc-migrate.log
TEMPO_DB_PORT=5435 bin/squirrel 2>&1 | tee /tmp/mc-squirrel.log
```
Expected: migrate reports the new migration applied; squirrel regenerates without error and `server/src/tempo/server/meeting/sql.gleam` now exists with the nine functions. Inspect that `meeting_attendees_asof`'s row type has `timezone: option.Option(String)` and `local_offset_minutes: option.Option(Int)` (LEFT JOIN nullability), and `meetings_upcoming` row has `client_id: option.Option(Int)`, `project_id: option.Option(Int)`, `location: option.Option(String)`, `starts_at: String`, `ends_at: String`, `canonical_offset_minutes: Int`.

- [ ] **Step 5: Confirm the server still builds.**

Run: `cd server && gleam build 2>&1 | tee /tmp/mc-build.log`
Expected: compiles (the generated `sql.gleam` is not yet referenced by any caller).

- [ ] **Step 6: Commit.**

```bash
git add server/priv/migrations/20260705120000_meeting.sql server/src/tempo/server/meeting/sql server/src/tempo/server/meeting/sql.gleam
git commit -m "Add meeting tables and typed SQL for schedule/reschedule/cancel/attendee writes and the upcoming read

Plain mutable meeting/meeting_detail/meeting_attendee rows (audit_id only, no bitemporal period); tstzrange composed from date+start+duration+tz via AT TIME ZONE; reads emit ISO-UTC instants plus per-zone offsets."
```

---

### Task 2: Meeting facts + repository write arms

**Files:**
- Modify: `server/src/tempo/server/fact.gleam` (add `MeetingId` anchor + five `Fact` variants)
- Modify: `server/src/tempo/server/repository.gleam` (add `create_meeting` + five `write` arms + import)
- Test: `server/test/meeting_test.gleam` (new; repository-level round-trip)

**Interfaces:**
- Consumes: `meeting/sql.gleam` functions from Task 1; `Recorded`, `Event`, `operation.run`, `operation.try` from `tempo/server/{fact,operation}`.
- Produces (consumed by Task 3's `meeting/command.gleam`): fact constructors
  `fact.MeetingScheduled(meeting_id: MeetingId, date: Date, starts_at: String, duration_minutes: Int, timezone: String, title: String, location: Option(String), client_id: Option(Int), project_id: Option(Int))`,
  `fact.MeetingRescheduled(meeting_id, date, starts_at, duration_minutes, timezone)`,
  `fact.MeetingCancelled(meeting_id)`,
  `fact.MeetingAttendeeAdded(meeting_id, engineer_id, attendance: String)`,
  `fact.MeetingAttendeeRemoved(meeting_id, engineer_id)`,
  and `repository.create_meeting(conn) -> Result(MeetingId, OperationError)`.

- [ ] **Step 1: Add the `MeetingId` anchor and `Fact` variants.**

In `server/src/tempo/server/fact.gleam`, after the `EngineerLocated(...)` variant (the current last arm of `Fact`, around line 289–295) add:

```gleam
  MeetingScheduled(
    meeting_id: MeetingId,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
    title: String,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
  )
  MeetingRescheduled(
    meeting_id: MeetingId,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
  )
  MeetingCancelled(meeting_id: MeetingId)
  MeetingAttendeeAdded(meeting_id: MeetingId, engineer_id: Int, attendance: String)
  MeetingAttendeeRemoved(meeting_id: MeetingId, engineer_id: Int)
```

And near the other anchor-id types (`EngineerId(Int)` etc., ~line 44) add:
```gleam
pub type MeetingId {
  MeetingId(Int)
}
```

- [ ] **Step 2: Run the build to see the exhaustiveness failures (RED).**

Run: `cd server && gleam clean && gleam build 2>&1 | tee /tmp/mc-fact.log`
Expected: FAIL — `repository.write`'s `case a_fact` is now inexhaustive (missing the five `Meeting*` arms). This is the red state that Step 3 satisfies.

- [ ] **Step 3: Add the repository import, `create_meeting`, and the five write arms.**

In `server/src/tempo/server/repository.gleam`:

Add to the imports (mirror `import tempo/server/location/sql as location_sql`, ~line 62):
```gleam
import tempo/server/meeting/sql as meeting_sql
```
Add the new fact constructors to the existing `import tempo/server/fact.{…}` list (the block importing `EngineerLocated`, `EngineerId`, etc., ~lines 46–59): add `MeetingId, MeetingScheduled, MeetingRescheduled, MeetingCancelled, MeetingAttendeeAdded, MeetingAttendeeRemoved`.

Add the anchor mint near `create_engineer` (~line 78):
```gleam
/// Mint a new meeting identity row; its detail and attendees follow as facts.
pub fn create_meeting(conn: pog.Connection) -> Result(MeetingId, OperationError) {
  use returned <- operation.try(meeting_sql.meeting_create(conn))
  let assert [row] = returned.rows
  Ok(MeetingId(row.id))
}
```

Add the five arms inside `write`'s `case a_fact { … }` (alongside the `EngineerLocated` arm, ~line 624):
```gleam
    MeetingScheduled(
      meeting_id: MeetingId(meeting_id),
      date:,
      starts_at:,
      duration_minutes:,
      timezone:,
      title:,
      location:,
      client_id:,
      project_id:,
    ) ->
      meeting_sql.meeting_detail_insert(
        conn,
        meeting_id,
        date,
        starts_at,
        duration_minutes,
        timezone,
        title,
        option.unwrap(location, ""),
        option.unwrap(client_id, 0),
        option.unwrap(project_id, 0),
        audit_id,
      )
      |> operation.run

    MeetingRescheduled(
      meeting_id: MeetingId(meeting_id),
      date:,
      starts_at:,
      duration_minutes:,
      timezone:,
    ) ->
      meeting_sql.meeting_reschedule(
        conn,
        meeting_id,
        date,
        starts_at,
        duration_minutes,
        timezone,
        audit_id,
      )
      |> require_covering_version

    MeetingCancelled(meeting_id: MeetingId(meeting_id)) ->
      meeting_sql.meeting_cancel(conn, meeting_id, audit_id)
      |> require_covering_version

    MeetingAttendeeAdded(
      meeting_id: MeetingId(meeting_id),
      engineer_id:,
      attendance:,
    ) ->
      meeting_sql.meeting_attendee_insert(conn, meeting_id, engineer_id, attendance)
      |> operation.run

    MeetingAttendeeRemoved(meeting_id: MeetingId(meeting_id), engineer_id:) ->
      meeting_sql.meeting_attendee_delete(conn, meeting_id, engineer_id)
      |> operation.run
```

(`require_covering_version` — the existing helper, ~line 651 — turns an empty `RETURNING` from reschedule/cancel into `NoSuchVersion`, so editing a missing meeting is a clean error rather than a silent no-op.)

- [ ] **Step 4: Build to green.**

Run: `cd server && gleam build 2>&1 | tee /tmp/mc-fact2.log`
Expected: PASS.

- [ ] **Step 5: Write the failing repository round-trip test.**

Create `server/test/meeting_test.gleam`. Model it on `server/test/location_test.gleam` (`rolling_back` + a bare-row insert helper). This step's test drives `repository` directly (Task 3 adds the command-level tests):

```gleam
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, Date, July}
import pog
import tempo/server/fact.{MeetingId, MeetingScheduled, MeetingAttendeeAdded}
import tempo/server/repository
import tempo/server/test_support.{rolling_back}

fn insert_engineer(conn: pog.Connection) -> Int {
  // mirror location_test.gleam:insert_engineer — returns a fresh engineer id
  todo
}

pub fn create_meeting_and_record_detail_and_attendee_test() {
  use conn <- rolling_back()
  let engineer_id = insert_engineer(conn)
  let assert Ok(fact.MeetingId(meeting_id)) = repository.create_meeting(conn)
  let facts = [
    MeetingScheduled(
      meeting_id: MeetingId(meeting_id),
      date: Date(2026, July, 10),
      starts_at: "09:00",
      duration_minutes: 60,
      timezone: "Europe/London",
      title: "Design review",
      location: Some("https://meet.example/xyz"),
      client_id: None,
      project_id: None,
    ),
    MeetingAttendeeAdded(
      meeting_id: MeetingId(meeting_id),
      engineer_id: engineer_id,
      attendance: "required",
    ),
  ]
  let outcome =
    list.try_map(facts, fn(a_fact) { repository.write(conn, 1, a_fact) })
  assert outcome |> is_ok
}
```

Note: `repository.write` and `create_meeting` must be `pub`. Confirm `rolling_back` / the bare-engineer insert helper exist in `location_test.gleam`; if the helper is private there, copy it into `meeting_test.gleam`. Replace `is_ok` with the codebase's existing ok-assertion idiom (grep `location_test.gleam`); if none, `let assert Ok(_) = outcome`.

- [ ] **Step 6: Run it — expect it to fail on the `todo` in `insert_engineer`, then implement the helper.**

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/mc-test.log`
Expected: hits `todo` (or a panic) in `insert_engineer`. Copy the real body from `location_test.gleam`'s engineer-insert helper, then re-run.
Expected after: PASS — the meeting/detail/attendee rows insert and the audit_id (1) is accepted (there must be an `event_log` row with id 1 in the rolled-back txn; if the FK rejects, first append a throwaway event via the same helper `operations_test.gleam` uses, or assert against `dispatch_in` in Task 3 instead and reduce this test to `create_meeting` + `meeting_attendee` only). Prefer: keep this test to `create_meeting` returning a positive id and a single `MeetingAttendeeAdded` (no audit FK), and defer detail-insert assertions to Task 3's `dispatch_in` test where a real `event_log` id exists.

- [ ] **Step 7: Commit.**

```bash
git add server/src/tempo/server/fact.gleam server/src/tempo/server/repository.gleam server/test/meeting_test.gleam
git commit -m "Record meeting writes as facts threaded with audit_id

MeetingScheduled/Rescheduled/Cancelled/AttendeeAdded/AttendeeRemoved map to plain INSERT/UPDATE/DELETE in repository.write; create_meeting mints the identity row. Reschedule/cancel gate a missing meeting via require_covering_version."
```

---

### Task 3: Shared command contract + dispatch wiring

**Files:**
- Create: `shared/src/shared/meeting/command.gleam`
- Create: `server/src/tempo/server/meeting/command.gleam`
- Modify: `shared/src/shared/command.gleam`, `shared/src/shared/access.gleam`, `shared/src/shared/access/policy.gleam`
- Modify: `server/src/tempo/server/auth.gleam`, `server/src/tempo/server/command.gleam`
- Modify: `server/test/codec_test.gleam`, `server/test/meeting_test.gleam`

**Interfaces:**
- Consumes: Task 2's fact constructors + `repository.create_meeting`; `meeting/sql.timezone_valid`.
- Produces (consumed by client Tasks 5–7 and the codec test): the `shared/meeting/command.gleam` public API
  `type Attendance { Required Optional }`,
  `type MeetingCommand { ScheduleMeeting(title, timezone, date, starts_at, duration_minutes, location: Option(String), client_id: Option(Int), project_id: Option(Int), attendees: List(#(Int, Attendance)))  RescheduleMeeting(meeting_id, timezone, date, starts_at, duration_minutes)  CancelMeeting(meeting_id)  AddAttendee(meeting_id, engineer_id, attendance: Attendance)  RemoveAttendee(meeting_id, engineer_id) }`,
  `encode(MeetingCommand) -> Json`, `decoder(op: String) -> Result(Decoder(MeetingCommand), Nil)`,
  plus `encode_attendance`/`attendance_decoder`.

- [ ] **Step 1: Write the shared command module.**

Create `shared/src/shared/meeting/command.gleam` (mirror `shared/location/command.gleam`; `Attendance` is a status type per house rules; `starts_at` is `"HH:MM"`):

```gleam
//// Write commands for meetings. Meetings are plain mutable rows, but writes still flow
//// through the dispatch/audit seam like every tstempo command; each is tagged by `op`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type Attendance {
  Required
  Optional
}

pub type MeetingCommand {
  ScheduleMeeting(
    title: String,
    timezone: String,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    location: Option(String),
    client_id: Option(Int),
    project_id: Option(Int),
    attendees: List(#(Int, Attendance)),
  )
  RescheduleMeeting(
    meeting_id: Int,
    timezone: String,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
  )
  CancelMeeting(meeting_id: Int)
  AddAttendee(meeting_id: Int, engineer_id: Int, attendance: Attendance)
  RemoveAttendee(meeting_id: Int, engineer_id: Int)
}

pub fn encode_attendance(attendance: Attendance) -> Json {
  case attendance {
    Required -> json.string("required")
    Optional -> json.string("optional")
  }
}

pub fn attendance_decoder() -> Decoder(Attendance) {
  use raw <- decode.then(decode.string)
  case raw {
    "optional" -> decode.success(Optional)
    _ -> decode.success(Required)
  }
}

fn encode_attendee(pair: #(Int, Attendance)) -> Json {
  let #(engineer_id, attendance) = pair
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("attendance", encode_attendance(attendance)),
  ])
}

fn attendee_decoder() -> Decoder(#(Int, Attendance)) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use attendance <- decode.field("attendance", attendance_decoder())
  decode.success(#(engineer_id, attendance))
}

pub fn encode(command: MeetingCommand) -> Json {
  case command {
    ScheduleMeeting(
      title:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
      location:,
      client_id:,
      project_id:,
      attendees:,
    ) ->
      json.object([
        #("op", json.string("schedule_meeting")),
        #("title", json.string(title)),
        #("timezone", json.string(timezone)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
        #("location", json.nullable(location, json.string)),
        #("client_id", json.nullable(client_id, json.int)),
        #("project_id", json.nullable(project_id, json.int)),
        #("attendees", json.array(attendees, encode_attendee)),
      ])
    RescheduleMeeting(
      meeting_id:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
    ) ->
      json.object([
        #("op", json.string("reschedule_meeting")),
        #("meeting_id", json.int(meeting_id)),
        #("timezone", json.string(timezone)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
      ])
    CancelMeeting(meeting_id:) ->
      json.object([
        #("op", json.string("cancel_meeting")),
        #("meeting_id", json.int(meeting_id)),
      ])
    AddAttendee(meeting_id:, engineer_id:, attendance:) ->
      json.object([
        #("op", json.string("add_attendee")),
        #("meeting_id", json.int(meeting_id)),
        #("engineer_id", json.int(engineer_id)),
        #("attendance", encode_attendance(attendance)),
      ])
    RemoveAttendee(meeting_id:, engineer_id:) ->
      json.object([
        #("op", json.string("remove_attendee")),
        #("meeting_id", json.int(meeting_id)),
        #("engineer_id", json.int(engineer_id)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(MeetingCommand), Nil) {
  case op {
    "schedule_meeting" ->
      Ok({
        use title <- decode.field("title", decode.string)
        use timezone <- decode.field("timezone", decode.string)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        use location <- decode.field("location", decode.optional(decode.string))
        use client_id <- decode.field("client_id", decode.optional(decode.int))
        use project_id <- decode.field("project_id", decode.optional(decode.int))
        use attendees <- decode.field("attendees", decode.list(attendee_decoder()))
        decode.success(ScheduleMeeting(
          title:,
          timezone:,
          date:,
          starts_at:,
          duration_minutes:,
          location:,
          client_id:,
          project_id:,
          attendees:,
        ))
      })
    "reschedule_meeting" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use timezone <- decode.field("timezone", decode.string)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        decode.success(RescheduleMeeting(
          meeting_id:,
          timezone:,
          date:,
          starts_at:,
          duration_minutes:,
        ))
      })
    "cancel_meeting" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        decode.success(CancelMeeting(meeting_id:))
      })
    "add_attendee" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use engineer_id <- decode.field("engineer_id", decode.int)
        use attendance <- decode.field("attendance", attendance_decoder())
        decode.success(AddAttendee(meeting_id:, engineer_id:, attendance:))
      })
    "remove_attendee" ->
      Ok({
        use meeting_id <- decode.field("meeting_id", decode.int)
        use engineer_id <- decode.field("engineer_id", decode.int)
        decode.success(RemoveAttendee(meeting_id:, engineer_id:))
      })
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 2: Wire `MeetingCommand` into the shared `Command` union.**

In `shared/src/shared/command.gleam`:
- Add import (after the `leave` import, alphabetical): `import shared/meeting/command as meeting_command`
- Add the union arm after `LocationCommand(...)`: `MeetingCommand(meeting_command.MeetingCommand)`
- Add to `encode_command`: `MeetingCommand(command) -> meeting_command.encode(command)`
- Add to `grouped_command_decoder` before `Error(Nil)`: `use <- try_group(meeting_command.decoder(op), MeetingCommand)`

- [ ] **Step 3: Add the permission constant and policy wiring.**

In `shared/src/shared/access.gleam`:
- After `pub const location_manage = "location.manage"` (line 82): `pub const meeting_manage = "meeting.manage"`
- Add `meeting_manage` to the `all()` list (after `location_manage,`, ~line 104).

In `shared/src/shared/access/policy.gleam`:
- Add `MeetingCommand` to the `Command`-variant import list (lines 17–24).
- Add `ManageMeeting` to `CommandKey` (after `ManageLocation`).
- Add to `requirement`: `ManageMeeting -> Direct(access.meeting_manage)`
- Add to `key`: `MeetingCommand(_) -> ManageMeeting`

- [ ] **Step 4: Add the server command_tag and dispatch route.**

In `server/src/tempo/server/auth.gleam`: add `MeetingCommand` to the `Command`-variant import (lines 20–27) and add to `command_tag`: `MeetingCommand(_) -> "manage_meeting"`.

In `server/src/tempo/server/command.gleam`: add `MeetingCommand` to the `Command`-variant import; add `import tempo/server/meeting/command as meeting` (after the `location` alias, ~line 43); add to `route`: `MeetingCommand(command) -> meeting.route(conn, command)`.

- [ ] **Step 5: Write the server command handler.**

Create `server/src/tempo/server/meeting/command.gleam` (mirror `location/command.gleam`: validate tz via `timezone_valid`, mint the id, return facts). Note `route` receives the minted `MeetingId` and builds one detail fact plus one `MeetingAttendeeAdded` per attendee:

```gleam
//// Write handler for meetings. schedule validates the TZID and mints a meeting id, then
//// records its detail and attendees as facts; the plain-mutable edits record one fact each.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog
import shared/command as gateway
import shared/meeting/command.{
  type Attendance, type MeetingCommand, AddAttendee, CancelMeeting, Optional,
  Required, RemoveAttendee, RescheduleMeeting, ScheduleMeeting,
}
import tempo/server/fact.{
  type Recorded, MeetingAttendeeAdded, MeetingAttendeeRemoved, MeetingCancelled,
  MeetingId, MeetingRescheduled, MeetingScheduled, Recorded,
}
import tempo/server/meeting/sql as meeting_sql
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

pub fn route(
  conn: pog.Connection,
  command: MeetingCommand,
) -> Result(Recorded, OperationError) {
  case command {
    ScheduleMeeting(
      title:,
      timezone:,
      date:,
      starts_at:,
      duration_minutes:,
      location:,
      client_id:,
      project_id:,
      attendees:,
    ) ->
      schedule(
        conn,
        command,
        title:,
        timezone:,
        date:,
        starts_at:,
        duration_minutes:,
        location:,
        client_id:,
        project_id:,
        attendees:,
      )
    RescheduleMeeting(meeting_id:, timezone:, date:, starts_at:, duration_minutes:) ->
      reschedule(
        conn,
        command,
        meeting_id:,
        timezone:,
        date:,
        starts_at:,
        duration_minutes:,
      )
    CancelMeeting(meeting_id:) -> Ok(cancel(command, meeting_id:))
    AddAttendee(meeting_id:, engineer_id:, attendance:) ->
      Ok(add_attendee(command, meeting_id:, engineer_id:, attendance:))
    RemoveAttendee(meeting_id:, engineer_id:) ->
      Ok(remove_attendee(command, meeting_id:, engineer_id:))
  }
}

fn attendance_tag(attendance: Attendance) -> String {
  case attendance {
    Required -> "required"
    Optional -> "optional"
  }
}

fn schedule(
  conn: pog.Connection,
  command: MeetingCommand,
  title title: String,
  timezone timezone: String,
  date date: Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
  location location: Option(String),
  client_id client_id: Option(Int),
  project_id project_id: Option(Int),
  attendees attendees: List(#(Int, Attendance)),
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(meeting_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(operation.InvalidValue)
    True -> {
      use meeting_id <- result_try(repository.create_meeting(conn))
      let fact.MeetingId(id) = meeting_id
      let detail =
        MeetingScheduled(
          meeting_id: MeetingId(id),
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          title:,
          location:,
          client_id:,
          project_id:,
        )
      let attendee_facts =
        list.map(attendees, fn(pair) {
          let #(engineer_id, attendance) = pair
          MeetingAttendeeAdded(
            meeting_id: MeetingId(id),
            engineer_id:,
            attendance: attendance_tag(attendance),
          )
        })
      Ok(Recorded(
        entry: Event(
          operation: "schedule_meeting",
          summary: "Scheduled \"" <> title <> "\" on " <> operation.iso(date)
            <> " " <> starts_at <> " (" <> timezone <> ")",
          payload: gateway.encode_command(gateway.MeetingCommand(command)),
        ),
        facts: [detail, ..attendee_facts],
      ))
    }
  }
}
```

Add the connection-less helpers `reschedule` (validate tz, return one `MeetingRescheduled` fact), `cancel` (return `MeetingCancelled`), `add_attendee` (return `MeetingAttendeeAdded` with `attendance_tag`), `remove_attendee` (return `MeetingAttendeeRemoved`), each building a `Recorded` with a descriptive `summary` and `payload: gateway.encode_command(gateway.MeetingCommand(command))`. `reschedule` mirrors `schedule`'s tz check; the other three take no `conn`. Provide the small `result_try` binding by importing `gleam/result` and using `result.try` (mirror how `location/command.gleam` sequences `operation.try`). If `create_meeting` should run only after tz validation (it should), keep the order above.

- [ ] **Step 6: Clean-build all three targets.**

Run:
```bash
cd /Users/michaelbuhot/src/mbuhot/tempo/server && gleam clean && gleam build 2>&1 | tee /tmp/mc-srv.log
cd /Users/michaelbuhot/src/mbuhot/tempo/shared && gleam build 2>&1 | tee /tmp/mc-shr.log
cd /Users/michaelbuhot/src/mbuhot/tempo/client && gleam build 2>&1 | tee /tmp/mc-cli.log
```
Expected: all compile. If `client` fails on `ui.build_command`/`op_command_key` exhaustiveness over the new `policy.ManageMeeting`, that is expected only if a client `case` matches `CommandKey` — resolve in Task 5/6; here only `shared`+`server` must be green, and `client` should still build because it does not yet match `MeetingCommand`.

- [ ] **Step 7: Add the codec round-trip test (RED then GREEN).**

In `server/test/codec_test.gleam` add `import shared/meeting/command as meeting_command` (and `Required`/`Optional`) and:
```gleam
pub fn command_schedule_meeting_round_trips_test() {
  let original =
    gateway.MeetingCommand(meeting_command.ScheduleMeeting(
      title: "Sprint kickoff",
      timezone: "Europe/London",
      date: Date(2026, July, 10),
      starts_at: "09:30",
      duration_minutes: 45,
      location: Some("https://meet.example/abc"),
      client_id: None,
      project_id: Some(3),
      attendees: [#(1, meeting_command.Required), #(2, meeting_command.Optional)],
    ))
  assert round_trip(original, gateway.encode_command, gateway.command_decoder())
    == original
}

pub fn command_cancel_meeting_round_trips_test() {
  let original = gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id: 5))
  assert round_trip(original, gateway.encode_command, gateway.command_decoder())
    == original
}
```
Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/mc-codec.log` — expect PASS.

- [ ] **Step 8: Add dispatch-level integration tests to `meeting_test.gleam`.**

Extend `server/test/meeting_test.gleam` with tests driving `command.dispatch_in(conn, "tester", command)` (mirror `location_test.gleam`), asserting via raw re-read SQL inside the rolled-back txn:
- schedule → a `meeting_detail` row exists with the composed `meeting_at` and a non-null `audit_id`, and one `meeting_attendee` per attendee;
- reschedule → `lower(meeting_at)` moved;
- cancel → `status = 'cancelled'`;
- add/remove attendee → the `meeting_attendee` row appears/disappears;
- an unknown timezone → `dispatch_in` yields `Error(operation.InvalidValue)`;
- reschedule of a non-existent meeting → `Error(operation.NoSuchVersion)`.

Use the `dispatch_in` helper shape from `location_test.gleam`. For the composed instant assertion, re-read `to_char(lower(meeting_at) AT TIME ZONE $tz, 'HH24:MI')` and assert it equals the input `starts_at`.

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/mc-disp.log` — expect PASS.

- [ ] **Step 9: Commit.**

```bash
git add shared/src/shared/meeting/command.gleam shared/src/shared/command.gleam shared/src/shared/access.gleam shared/src/shared/access/policy.gleam server/src/tempo/server/meeting/command.gleam server/src/tempo/server/auth.gleam server/src/tempo/server/command.gleam server/test/codec_test.gleam server/test/meeting_test.gleam
git commit -m "Add MeetingCommand and route it through dispatch to meeting facts

Five commands (schedule/reschedule/cancel/add/remove attendee) with JSON codecs, a meeting.manage permission and ManageMeeting policy key, tz validation, and the server route producing detail+attendee facts."
```

---

### Task 4: Read model, HTTP endpoint, router, and seed

**Files:**
- Create: `shared/src/shared/meeting/view.gleam`
- Create: `server/src/tempo/server/meeting/view.gleam`
- Create: `server/src/tempo/server/meeting/http.gleam`
- Modify: `server/src/tempo/server/web/router.gleam`
- Modify: `server/priv/seed/base_seed.sql`, `server/priv/seed/rbac_seed.sql`
- Test: `server/test/api_test.gleam`

**Interfaces:**
- Consumes: Task 1 read SQL (`meetings_upcoming`, `meeting_attendees_asof`); `context.Context`.
- Produces (consumed by client Task 5): `shared/meeting/view.gleam`
  `type MeetingRecord(id, title, meeting_tz, starts_at: String, ends_at: String, canonical_offset_minutes: Int, location: Option(String), client_id: Option(Int), project_id: Option(Int), attendees: List(AttendeeRecord))`,
  `type AttendeeRecord(engineer_id, name, attendance: Attendance, timezone: Option(String), local_offset_minutes: Option(Int))`,
  `encode_meeting_record`, `meeting_record_decoder`; and `GET /api/meetings?as_of=` returning a JSON array of them.

- [ ] **Step 1: Write the shared read types + codecs.**

Create `shared/src/shared/meeting/view.gleam`, reusing `Attendance` from `shared/meeting/command`. Fields exactly as the Interfaces block above; `starts_at`/`ends_at` are ISO-8601 UTC strings. Mirror `shared/location/view.gleam`'s encoder/decoder style (`json.object` + `decode.field`). Encode `attendance` via `command.encode_attendance` and decode via `command.attendance_decoder`.

- [ ] **Step 2: Write the server view (fold meetings + attendees).**

Create `server/src/tempo/server/meeting/view.gleam` mirroring `location/view.gleam`'s two-query fold: run `meetings_upcoming(db, as_of)` and `meeting_attendees_asof(db, as_of)`, group attendee rows into a `dict` keyed by `meeting_id`, and build each `MeetingRecord` with its attendee list. Map an attendee row's `attendance` string to `Required`/`Optional` (default `Required`). `timezone`/`local_offset_minutes` stay `Option`. Public entrypoint:
```gleam
pub fn upcoming(context: Context, as_of: Date) -> Result(List(MeetingRecord), pog.QueryError)
```

- [ ] **Step 3: Write the HTTP handler.**

Create `server/src/tempo/server/meeting/http.gleam` mirroring `location/http.gleam:handle_listing`: require `http.Get`, parse `as_of` via `request.date_from_query(req, "as_of")`, call `view.upcoming`, encode via `meeting_view.encode_meeting_record` in a `json.array`, map errors with `response.db_error_response`.

- [ ] **Step 4: Register the route.**

In `server/src/tempo/server/web/router.gleam`: add `import tempo/server/meeting/http as meeting_http` (with the other handler imports, ~line 30) and, before the `["api", ..] -> wisp.not_found()` catch-all, add:
```gleam
    ["api", "meetings"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      meeting_http.handle_listing(request, context)
    }
```

- [ ] **Step 5: Seed meetings + the permission grant.**

In `server/priv/seed/rbac_seed.sql`:
- Add the permission row (turn the current final `location.manage` row's `;` into `,` and append):
  `('meeting.manage', 'Manage meetings');`
- In the `role_permission` VALUES list, add after the `owner`/`location.manage` grant (fix trailing commas): `('manager', 'meeting.manage'), ('owner', 'meeting.manage')`.

In `server/priv/seed/base_seed.sql`, after the engineer-location block (~line 559), add two scheduled meetings using the `WITH e AS (INSERT INTO event_log … RETURNING id)` shape. Choose deterministic times relative to seed-now 2026-06-15 that survive the upcoming filter, and attendees spanning zones (Priya=1 London-from-July, Marcus=2 LA, Aisha=3 London):
```sql
-- Seed meetings (scheduling Phase C): a July all-hands spanning three zones, and a
-- June client sync, both after seed-now (2026-06-15) so the upcoming read returns them.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-01', 'seed', 'schedule_meeting',
     'Scheduled "July all-hands" on 2026-07-10 09:00 (Europe/London)',
     '{"title":"July all-hands","timezone":"Europe/London","date":"2026-07-10","starts_at":"09:00","duration_minutes":60,"location":null,"client_id":null,"project_id":null,"attendees":[{"engineer_id":1,"attendance":"required"},{"engineer_id":2,"attendance":"optional"},{"engineer_id":3,"attendance":"required"}]}')
  RETURNING id),
m AS (INSERT INTO meeting DEFAULT VALUES RETURNING id),
d AS (
  INSERT INTO meeting_detail (meeting_id, meeting_at, meeting_tz, title, location, status, client_id, project_id, audit_id)
  SELECT m.id,
    tstzrange(('2026-07-10 09:00'::timestamp AT TIME ZONE 'Europe/London'),
              ('2026-07-10 09:00'::timestamp AT TIME ZONE 'Europe/London') + interval '60 minutes', '[)'),
    'Europe/London', 'July all-hands', NULL, 'scheduled', NULL, NULL, e.id
  FROM m, e RETURNING meeting_id)
INSERT INTO meeting_attendee (meeting_id, engineer_id, attendance)
SELECT d.meeting_id, v.engineer_id, v.attendance
FROM d, (VALUES (1, 'required'), (2, 'optional'), (3, 'required')) AS v(engineer_id, attendance);
```
Add a second, simpler meeting the same way for a June client sync if a second row aids the e2e/api assertions.

Run: `TEMPO_DB_PORT=5435 bin/reseed 2>&1 | tee /tmp/mc-reseed.log` (destructive; dev DB). Then re-apply the test DB via the harness `bin/test` will handle.

- [ ] **Step 6: Write the API test (RED then GREEN).**

In `server/test/api_test.gleam`, add a test that GETs `/api/meetings?as_of=2026-07-05` via the `read(...)` helper (routes as `admin()`), decodes the array with `meeting_view.meeting_record_decoder`, and asserts: the "July all-hands" record is present; its `canonical_offset_minutes == 60` (London in July); its attendees include Priya (id 1) with `timezone == Some("Europe/London")` and `local_offset_minutes == Some(60)`, and Marcus (id 2) with `local_offset_minutes == Some(-420)` (LA in July). Also assert `read` without `access.read_engineers` returns 403 by routing as a permissionless principal (mirror an existing 403 assertion in `api_test.gleam`).

Run: `cd server && TEMPO_DB_PORT=5435 bin/test 2>&1 | tee /tmp/mc-api.log`
Expected: PASS (base seed contains the seeded meeting).

- [ ] **Step 7: Commit.**

```bash
git add shared/src/shared/meeting/view.gleam server/src/tempo/server/meeting/view.gleam server/src/tempo/server/meeting/http.gleam server/src/tempo/server/web/router.gleam server/priv/seed/base_seed.sql server/priv/seed/rbac_seed.sql server/test/api_test.gleam
git commit -m "Serve GET /api/meetings with per-attendee local offsets; seed meetings + meeting.manage

Upcoming scheduled meetings anchored to as-of, each attendee's timezone resolved from engineer_location as-of the date and its UTC offset computed at the meeting start."
```

---

### Task 5: Calendar page — upcoming list + nav/route wiring

**Files:**
- Create: `client/src/client/page/meetings.gleam`
- Modify: `client/src/client/route.gleam`, `client/src/client/app.gleam`, `client/src/client/icons.gleam`
- Modify: `client/src/client/api.gleam` (add a `fetch_meetings` if the page uses a shared fetch helper; otherwise inline `rsvp.get`)

**Interfaces:**
- Consumes: `shared/meeting/view.{MeetingRecord, meeting_record_decoder}`; the frozen page interface from `page/locations.gleam`.
- Produces: `meetings.{Model, Msg, init, refetch, update, view}` with the exact frozen signatures (see below), plus `route.Meetings`.

- [ ] **Step 1: Add the route.**

In `client/src/client/route.gleam`: add `Meetings` to `Route`; `["meetings"] -> Meetings` in `parse`; `Meetings -> "/meetings"` in `to_path`; `route.Meetings, route.Meetings -> True` in `route_matches` (if that fn lives in `app.gleam`, add it there per Step 4).

- [ ] **Step 2: Add a nav icon.**

In `client/src/client/icons.gleam` add a `pub fn meetings() -> Element(msg)` (copy the `locations()` icon shape; a calendar glyph path is fine — reuse `locations()`'s SVG wrapper and swap the `d` path, or reuse an existing calendar-like icon if present).

- [ ] **Step 3: Write the page skeleton (list view only).**

Create `client/src/client/page/meetings.gleam` exposing the frozen interface (mirror `page/locations.gleam`), with load-state and no write ops yet:
```gleam
pub type State {
  MeetingsLoading
  MeetingsLoaded(records: List(MeetingRecord))
  MeetingsFailed(detail: String)
}
pub type Model {
  Model(as_of: Date, actor: String, state: State, op: Option(ui.OpState))
}
pub type Msg {
  Fetched(as_of: Date, result: Result(List(MeetingRecord), rsvp.Error(String)))
}
pub fn init(_route, as_of: Date, actor: String) -> #(Model, Effect(Msg))
pub fn refetch(model: Model, as_of: Date, actor: String) -> #(Model, Effect(Msg))
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(page.OutMsg))
pub fn view(model: Model, as_of: Date, permissions: Set(String)) -> Element(Msg)
```
`init`/`refetch` issue `GET /api/meetings?as_of=<date>` (format the date with the same helper `locations.gleam` uses), decoding with `json.array`/`meeting_record_decoder`, tagged `Fetched(as_of, _)` with the stale-guard (ignore a result whose `as_of` ≠ current). `view` renders each meeting: title, canonical time (format the ISO `starts_at` shifted by `canonical_offset_minutes`, labelled with `time.utc_offset(canonical_offset_minutes)` and the `meeting_tz`), and a per-attendee line showing each attendee's local time (shift `starts_at` by `local_offset_minutes` when `Some`, else "no location") with a required/optional marker. Provide a private helper `local_time(starts_at_iso: String, offset_minutes: Int) -> String` that parses the ISO instant and applies the offset; unit-test it in Step 6.

- [ ] **Step 4: Wire the page into the shell.**

In `client/src/client/app.gleam` add, mirroring every `Locations`/`LocationsPage`/`LocationsMsg` site (the dossier lists them): the `import client/page/meetings`, the `MeetingsPage(meetings.Model)` `Page` arm, the `MeetingsMsg(meetings.Msg)` `Msg` arm, the update-dispatch block, the `route.Meetings ->` init arm, the `MeetingsPage(model) ->` refetch arm, the nav link `nav_link_if(permissions, perm.read_engineers, active, as_of, route.Meetings, icons.meetings(), "Meetings")`, the `route_matches` arm, and the `MeetingsPage(page) ->` view arm.

- [ ] **Step 5: Build the client.**

Run: `cd client && gleam build 2>&1 | tee /tmp/mc-cli5.log`
Expected: compiles.

- [ ] **Step 6: Add a pure-function test for local-time formatting (RED then GREEN).**

Create `client/test/meeting_command_test.gleam` (this file also holds Task 6/7 tests) with:
```gleam
import client/page/meetings

pub fn local_time_applies_a_positive_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", 60) == "10:00"
}
pub fn local_time_applies_a_negative_offset_test() {
  assert meetings.local_time("2026-07-10T09:00:00Z", -420) == "02:00"
}
```
Mark `local_time` `pub`. Run: `cd client && gleam test 2>&1 | tee /tmp/mc-cli6.log` — expect PASS. (Adjust the expected strings to the exact format `local_time` produces — decide `HH:MM` and keep it deterministic; the assertions must match the implementation exactly.)

- [ ] **Step 7: Commit.**

```bash
git add client/src/client/page/meetings.gleam client/src/client/route.gleam client/src/client/app.gleam client/src/client/icons.gleam client/test/meeting_command_test.gleam
git commit -m "Add a Calendar page listing upcoming meetings in each attendee's local time

New /meetings route + nav entry; the page fetches GET /api/meetings anchored to the as-of date and renders canonical and per-attendee local times from the wire offsets."
```

---

### Task 6: Granular edit ops via the op-form engine

**Files:**
- Modify: `client/src/client/ui.gleam` (OpKind, op_command_key, OpField, OpForm, blank_op_form, update_op_form, build_command)
- Modify: `client/src/client/page/meetings.gleam` (op state, launchers, modals, submit)
- Test: `client/test/meeting_command_test.gleam`

**Interfaces:**
- Consumes: `shared/meeting/command.{RescheduleMeeting, CancelMeeting, AddAttendee, RemoveAttendee, Required, Optional}`; `ui.{OpState, build_command, submit …}`.
- Produces: four new `OpKind`s (`OpRescheduleMeeting`, `OpCancelMeeting`, `OpAddAttendee`, `OpRemoveAttendee`) and their `build_command` arms; the page's per-kind field lists, titles, and confirm labels; row edit/cancel actions.

- [ ] **Step 1: Extend `ui.gleam` with the four edit kinds and their fields.**

In `client/src/client/ui.gleam`:
- Add `import shared/meeting/command as meeting_command`.
- `OpKind`: add `OpRescheduleMeeting`, `OpCancelMeeting`, `OpAddAttendee`, `OpRemoveAttendee`.
- `op_command_key`: map all four to `policy.ManageMeeting`.
- `OpField`: add `FMeetingId`, `FStartsAt`, `FDurationMinutes`, `FAttendance` (reuse existing `FEngineerId`, `FTimezone`, and `FEffective` for the meeting date).
- `OpForm`: add string fields `meeting_id`, `starts_at`, `duration_minutes`, `attendance`.
- `blank_op_form`: seed the four new fields `""` (or a sensible default like `attendance: "required"`, `duration_minutes: "60"`).
- `update_op_form`: add arms `FMeetingId -> OpForm(..form, meeting_id: value)`, `FStartsAt -> …`, `FDurationMinutes -> …`, `FAttendance -> …`.

- [ ] **Step 2: Add the four `build_command` arms (RED then GREEN via Step 5 test).**

In `build_command`, before the final `OpCreateProject -> Error(...)` arm, add (using the validators `require_int`/`require_text`/`require_date`):
```gleam
    OpRescheduleMeeting -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use timezone <- result.try(require_text(form.timezone, "timezone"))
      use date <- result.try(require_date(form.effective, "date"))
      use starts_at <- result.try(require_text(form.starts_at, "start time"))
      use duration_minutes <- result.try(require_int(form.duration_minutes, "duration"))
      Ok(gateway.MeetingCommand(meeting_command.RescheduleMeeting(
        meeting_id:, timezone:, date:, starts_at:, duration_minutes:,
      )))
    }
    OpCancelMeeting -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      Ok(gateway.MeetingCommand(meeting_command.CancelMeeting(meeting_id:)))
    }
    OpAddAttendee -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      let attendance = case form.attendance {
        "optional" -> meeting_command.Optional
        _ -> meeting_command.Required
      }
      Ok(gateway.MeetingCommand(meeting_command.AddAttendee(
        meeting_id:, engineer_id:, attendance:,
      )))
    }
    OpRemoveAttendee -> {
      use meeting_id <- result.try(require_int(form.meeting_id, "meeting id"))
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      Ok(gateway.MeetingCommand(meeting_command.RemoveAttendee(
        meeting_id:, engineer_id:,
      )))
    }
```

- [ ] **Step 3: Add op state, launchers, modals, and submit to the page.**

In `client/src/client/page/meetings.gleam` add (mirror `locations.gleam`'s op mechanics): `op: Option(ui.OpState)` is already on `Model`; extend `Msg` with `OpOpened(ui.Permit, OpKind, prefill)`, `OpCancelled`, `OpFieldEdited(ui.OpField, String)`, `OpSubmitted`, `OperationReturned(Result(Nil, rsvp.Error(String)))`. On `OpSubmitted` call `ui.build_command(kind, form)` then `api.submit_operation(command, OperationReturned)`; on `OperationReturned(Ok(_))` refetch and emit `[page.OperationCommitted]`. Add per-meeting-row "Reschedule"/"Cancel" launchers gated by `ui.launch(ui.permit(permissions, own: False, kind: ui.OpRescheduleMeeting), …)` etc., prefilling `FMeetingId` (and reschedule prefilling current date/start/duration/tz). Add an "Add attendee"/"Remove attendee" affordance per meeting. The modal `title`/`confirm_label` and the per-kind `op_fields(kind, form)` list live in this page (there is no central `op_title`).

- [ ] **Step 4: Build the client.**

Run: `cd client && gleam clean && gleam build 2>&1 | tee /tmp/mc-cli6b.log` (clean-build for the new `OpKind` variants).
Expected: compiles (all `case OpKind` sites — `op_command_key`, `build_command`, `update_op_form`, and any page field list — handle the four new kinds).

- [ ] **Step 5: Test the four builders (RED then GREEN).**

Add to `client/test/meeting_command_test.gleam`:
```gleam
import client/ui
import shared/command as gateway
import shared/meeting/command as meeting_command

pub fn build_reschedule_command_test() {
  let form =
    ui.blank_op_form(ui.OpRescheduleMeeting, calendar.Date(2026, calendar.July, 10))
    |> ui.update_op_form(ui.FMeetingId, "7")
    |> ui.update_op_form(ui.FTimezone, "Europe/London")
    |> ui.update_op_form(ui.FEffective, "2026-07-11")
    |> ui.update_op_form(ui.FStartsAt, "14:00")
    |> ui.update_op_form(ui.FDurationMinutes, "30")
  assert ui.build_command(ui.OpRescheduleMeeting, form)
    == Ok(gateway.MeetingCommand(meeting_command.RescheduleMeeting(
      meeting_id: 7, timezone: "Europe/London",
      date: calendar.Date(2026, calendar.July, 11),
      starts_at: "14:00", duration_minutes: 30,
    )))
}

pub fn build_cancel_command_rejects_missing_id_test() {
  let form = ui.blank_op_form(ui.OpCancelMeeting, calendar.Date(2026, calendar.July, 10))
  assert ui.build_command(ui.OpCancelMeeting, form) |> result.is_error
}
```
Confirm `ui.blank_op_form` / `ui.update_op_form` / `ui.build_command` are `pub` (make them so if not — `build_command` is used by pages so it is already `pub`; `blank_op_form`/`update_op_form` likely are too). Run: `cd client && gleam test 2>&1 | tee /tmp/mc-cli6c.log` — expect PASS.

- [ ] **Step 6: Commit.**

```bash
git add client/src/client/ui.gleam client/src/client/page/meetings.gleam client/test/meeting_command_test.gleam
git commit -m "Reschedule/cancel/add/remove meeting attendees via the op-form engine

Four new OpKinds gated by ManageMeeting build the granular meeting edit commands; the Calendar rows launch them as modals."
```

---

### Task 7: Bespoke ScheduleMeeting create form

**Files:**
- Modify: `client/src/client/page/meetings.gleam` (create-form model, attendee builder, direct command build, submit)
- Modify: `client/src/client/api.gleam` (add a roster fetch if none exists) or reuse an existing engineer-roster fetch
- Test: `client/test/meeting_command_test.gleam`

**Interfaces:**
- Consumes: `shared/meeting/command.{ScheduleMeeting, Attendance, Required, Optional}`; `api.submit_operation`; the engineer roster (`GET /api/locations?as_of=` already returns `(engineer_id, name)` for all engineers via `EngineerLocation`, or add a dedicated roster fetch).
- Produces: a page-local `CreateForm` model + `build_schedule_command(form) -> Result(Command, String)` (pure, testable), driving `api.submit_operation`.

- [ ] **Step 1: Model the create form and typed attendee list.**

In `page/meetings.gleam` add:
```gleam
pub type Attendee {
  Attendee(engineer_id: Int, attendance: meeting_command.Attendance)
}
pub type CreateForm {
  CreateForm(
    title: String,
    timezone: String,
    date: String,
    starts_at: String,
    duration_minutes: String,
    location: String,
    client_id: String,
    project_id: String,
    attendees: List(Attendee),
    query: String,
    error: Option(String),
  )
}
```
Add a `create: Option(CreateForm)` field to `Model` (or fold into a `Screen` sum type if that reads cleaner). Extend `Msg` with `CreateOpened`, `CreateCancelled`, `CreateFieldEdited(field, value)`, `AttendeeQueryChanged(String)`, `AttendeeAdded(Int)`, `AttendeeRemoved(Int)`, `AttendanceSet(Int, Attendance)`, `CreateSubmitted`. The row-surgery on `attendees` mirrors `client/workflow/edit.gleam`'s add/remove pattern (append, and filter-by-index) — implement as small private helpers, not by importing the workflow module.

- [ ] **Step 2: Write the pure command builder (RED then GREEN via Step 5).**

Add:
```gleam
pub fn build_schedule_command(form: CreateForm) -> Result(gateway.Command, String) {
  use duration <- result.try(
    int.parse(form.duration_minutes) |> result.replace_error("duration must be a number"),
  )
  use date <- result.try(parse_date(form.date))
  case form.title, form.timezone, form.attendees {
    "", _, _ -> Error("title is required")
    _, "", _ -> Error("timezone is required")
    _, _, [] -> Error("add at least one attendee")
    title, timezone, attendees ->
      Ok(gateway.MeetingCommand(meeting_command.ScheduleMeeting(
        title:,
        timezone:,
        date:,
        starts_at: form.starts_at,
        duration_minutes: duration,
        location: optional_text(form.location),
        client_id: optional_int(form.client_id),
        project_id: optional_int(form.project_id),
        attendees: list.map(attendees, fn(a) { #(a.engineer_id, a.attendance) }),
      )))
  }
}
```
Provide `optional_text`/`optional_int` (trim → `None` on empty) and `parse_date` (reuse the same date parser `ui.require_date` uses, or `wire`/`calendar` parsing already present in the client — grep for how `locations.gleam` parses `effective`).

- [ ] **Step 3: Render the create form with the attendee builder.**

`view` (when `create` is `Some`) renders the scalar inputs (title, tz picker defaulting to the viewer's own location tz as-of the date — resolve from the loaded records or the roster), date/start/duration, optional location/client/project, then the attendee builder: a search input filtering the roster by name (client-side `string.contains`), an add control per match, and the current attendee rows each with a required/optional select and a remove button. The tz picker options can be a static list of the IANA zones already present in the roster plus the viewer's own; a free-text input validated server-side is acceptable for Phase C.

- [ ] **Step 4: Submit builds the command directly.**

On `CreateSubmitted`, call `build_schedule_command(form)`; on `Ok(command)` call `api.submit_operation(command, OperationReturned)`; on `Error(msg)` set `form.error`. `OperationReturned(Ok)` closes the form, refetches, and emits `[page.OperationCommitted]`. Gate the "New meeting" launcher with `ui.permit(permissions, own: False, kind: ui.OpAddAttendee)` — reuse any `ManageMeeting`-keyed kind for the permission check, or check `set.contains(permissions, perm.meeting_manage)` directly if a `perm` alias exists.

- [ ] **Step 5: Test the builder (RED then GREEN).**

Add to `client/test/meeting_command_test.gleam`:
```gleam
pub fn build_schedule_command_from_a_valid_form_test() {
  let form =
    meetings.CreateForm(
      title: "Kickoff", timezone: "Europe/London", date: "2026-07-10",
      starts_at: "09:30", duration_minutes: "45", location: "",
      client_id: "", project_id: "3",
      attendees: [meetings.Attendee(1, meeting_command.Required),
                  meetings.Attendee(2, meeting_command.Optional)],
      query: "", error: option.None,
    )
  assert meetings.build_schedule_command(form)
    == Ok(gateway.MeetingCommand(meeting_command.ScheduleMeeting(
      title: "Kickoff", timezone: "Europe/London",
      date: calendar.Date(2026, calendar.July, 10),
      starts_at: "09:30", duration_minutes: 45,
      location: option.None, client_id: option.None, project_id: option.Some(3),
      attendees: [#(1, meeting_command.Required), #(2, meeting_command.Optional)],
    )))
}
pub fn build_schedule_command_requires_an_attendee_test() {
  let form =
    meetings.CreateForm(
      title: "Kickoff", timezone: "Europe/London", date: "2026-07-10",
      starts_at: "09:30", duration_minutes: "45", location: "",
      client_id: "", project_id: "", attendees: [], query: "", error: option.None,
    )
  assert meetings.build_schedule_command(form) == Error("add at least one attendee")
}
```
Run: `cd client && gleam test 2>&1 | tee /tmp/mc-cli7.log` — expect PASS.

- [ ] **Step 6: Build + commit.**

```bash
cd client && gleam build 2>&1 | tee /tmp/mc-cli7b.log
git add client/src/client/page/meetings.gleam client/src/client/api.gleam client/test/meeting_command_test.gleam
git commit -m "Schedule meetings from a bespoke attendee-list form

A typed create form builds a repeated attendee list (name-search + required/optional) and submits ScheduleMeeting directly, since the scalar op-form engine cannot hold a repeated field."
```

---

### Task 8: End-to-end flow

**Files:**
- Create: `e2e/meetings.spec.js`

**Interfaces:**
- Consumes: the demo/e2e seed's meetings (Task 4) + `meeting.manage` grant; the running client bundle (`bin/e2e` rebuilds it first).

- [ ] **Step 1: Write the Playwright spec.**

Create `e2e/meetings.spec.js` mirroring `e2e/locations.spec.js` (sign-in helper, as-of control). Cover, asserting user-visible content (no CSS/DOM internals):
- Navigate to Calendar at as-of 2026-07-05; the "July all-hands" meeting is listed with London canonical time and both Priya's London local time and Marcus's LA local time shown.
- Open "New meeting", fill title/tz/date/start/duration, add two attendees (search by name), mark one optional, submit; the new meeting appears in the list.
- Reschedule that meeting to a later time; the listed time updates.
- Cancel it; it disappears from the list.
- Sign in as a role without `meeting.manage`; the "New meeting" launcher and row edit actions are absent.

- [ ] **Step 2: Run e2e.**

Run: `TEMPO_DB_PORT=5435 bin/e2e meetings 2>&1 | tee /tmp/mc-e2e.log` (bin/e2e rebuilds the client bundle first — do not skip it).
Expected: PASS. If a stale bundle causes a false failure, re-run `bin/build` then `bin/e2e`.

- [ ] **Step 3: Commit.**

```bash
git add e2e/meetings.spec.js
git commit -m "e2e: schedule, reschedule, and cancel a meeting; attendee-local times and RBAC"
```

---

## Final gate (after Task 8)

Run the full suite:
```bash
cd /Users/michaelbuhot/src/mbuhot/tempo/server && gleam clean && gleam build 2>&1 | tee /tmp/mc-final-srv.log
cd /Users/michaelbuhot/src/mbuhot/tempo/shared && gleam build 2>&1 | tee /tmp/mc-final-shr.log
cd /Users/michaelbuhot/src/mbuhot/tempo/client && gleam clean && gleam build 2>&1 | tee /tmp/mc-final-cli.log
cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/test 2>&1 | tee /tmp/mc-final-test.log
cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/e2e 2>&1 | tee /tmp/mc-final-e2e.log
```
Expected: all green. Then update issue #44/#42 status (show text for approval before posting) and the `scheduling-system` memory.

---

## Self-Review notes

- **Spec coverage:** C1 (plain mutable) → Task 1 schema + Task 2 fact/write arms; C2/C3 (`tstzrange`/`meeting_tz`) → Task 1 SQL; C4 (date+start+duration+tz) → Task 1 composition + Task 3 command; C5/C6 (five commands, bespoke create + flat edits) → Tasks 3/6/7; C7 (`meeting.manage`) → Task 3 + seed Task 4; C8 (upcoming list) → Task 5; C9 (name-search required/optional, bulk deferred) → Task 7; per-attendee local time → Task 4 view + Task 5 render; D-cancel (drop cancelled) → Task 1 read filter; D-edits (flat op-form) → Task 6. Error handling (tz/duration/permission/missing) → Task 3 tz+`require_covering_version`, Task 6/7 validation, Task 4 403. Testing matrix → Tasks 2–8.
- **Deferred to Phase D (not in this plan):** the finder, bulk attendee add, booking concurrency, time-grid — per spec "Out of scope".
- **Assumption to verify in Task 1:** Squirrel types the `meetings_upcoming` `client_id`/`project_id`/`location` as `Option` (they are nullable columns) and `meeting_attendees_asof` `timezone`/`local_offset_minutes` as `Option` (LEFT JOIN). If Squirrel instead infers NOT NULL and crashes on the open rows (the Phase A pitfall), apply the `coalesce`/`nullif` guard used in `location`'s queries.
- **Assumption to verify in Task 2:** the `event_log` FK on `meeting_detail.audit_id` means the repository round-trip test needs a real event id; the plan routes that assertion through Task 3's `dispatch_in` test (where `record_facts` appends a real event) rather than the bare repository test.
