# Scheduling Phase C — Meetings (design)

**Issue:** #44 (part of #42) · **Depends on:** Phase A (#46/#47 shipped) · **Precedes:** the finder (#45)
**Prior art:** Layer C of `docs/2026-07-04-scheduling-calendar-design.md`; UI prototype `docs/prototypes/2026-07-04-scheduling.html`.

## Problem

tempo tracks a distributed workforce whose members sit in different timezones. Phase A made an
engineer's timezone an as-of query (location is a dated fact carrying an IANA TZID). Phase C adds
the meetings themselves: schedule a meeting at an absolute time, invite attendees, and read it back
in every attendee's own local time so a cross-timezone slot's fairness is visible. Phase D (the
finder) then suggests slots; Phase C is the create/edit/cancel surface it books into.

A meeting carries no fact history worth versioning — a reschedule replaces the time, it doesn't
record "the time it used to be." So meetings are **plain mutable rows**, not bitemporal facts. The
`event_log` audit seam still records who changed what and when, as it does for every tempo write.

## Core decisions

| # | Decision | Rationale |
|---|---|---|
| C1 | Meetings are plain mutable rows; reschedule/cancel are in-place `UPDATE`s | no per-meeting fact history is meaningful; `event_log` covers who/when |
| C2 | `meeting_at` is a `tstzrange` of absolute instants — the single source of truth for when | timezone-independent; renders into any viewer/attendee tz |
| C3 | Persist `meeting_tz` (IANA TZID) as the meeting's canonical timezone | supports "schedule this in the client's tz"; editing reloads the wall-clock in the tz it was set in; validated vs `pg_timezone_names` like location |
| C4 | The organizer enters date + start time + duration under an explicit tz picker (defaulting to their own location tz) | the server composes the `tstzrange`; a duration picker matches how the finder later hands off a chosen slot |
| C5 | Five commands: one composite `ScheduleMeeting` (carries the attendee list), four granular edits | one-shot creation; edits stay simple and reuse the flat op-form engine |
| C6 | `ScheduleMeeting`'s attendee-list form is **bespoke UI** on the Calendar page; the four granular edits use the flat `ui.gleam` op-form engine | the frozen `OpForm` record is all-scalar and cannot hold a repeated field; see "Create form" below |
| C7 | New `meeting.manage` permission, mirroring `location.manage`'s grant | consistent with Phase A's write gating |
| C8 | Phase C Calendar view is an upcoming-meetings list anchored to the as-of date; a time-grid is deferred | simplest correct surface; the grid is premature before the finder exists |
| C9 | Attendee pick is name-search autocomplete over current engineers, marked required or optional; bulk add ("everyone"/"from project") is deferred to the finder wizard (Phase D) | keeps Phase C focused; `attendance` is stored and displayed now so D can gate on it |

**Defaults carried into the spec (open to veto at review):**
- **D-cancel:** cancelled meetings drop off the upcoming list (no "show cancelled" toggle in Phase C).
- **D-edits:** the four granular edits (reschedule/cancel/add-attendee/remove-attendee) go through the flat op-form engine as new `OpKind`s, the standard gated write path.

## Schema (one migration, no bitemporal facts)

```sql
CREATE TABLE meeting (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY);

CREATE TABLE meeting_detail (
  meeting_id bigint    PRIMARY KEY REFERENCES meeting (id),
  meeting_at tstzrange NOT NULL,                       -- absolute instants (source of truth)
  meeting_tz text      NOT NULL,                       -- IANA TZID, validated vs pg_timezone_names
  title      text      NOT NULL,
  location   text,                                     -- free-text link/address, no availability constraint
  status     text      NOT NULL DEFAULT 'scheduled',   -- scheduled | cancelled
  client_id  bigint    REFERENCES client (id),
  project_id bigint    REFERENCES project (id),
  audit_id   bigint    NOT NULL REFERENCES event_log (id)
);

CREATE TABLE meeting_attendee (
  meeting_id  bigint NOT NULL REFERENCES meeting (id) ON DELETE CASCADE,
  engineer_id bigint NOT NULL REFERENCES engineer (id),
  attendance  text   NOT NULL DEFAULT 'required',      -- required | optional
  PRIMARY KEY (meeting_id, engineer_id)
);
```

`meeting_detail` splits from `meeting` so a future need can add a second detail dimension without
touching the identity row; it mirrors the design doc's shape plus the `meeting_tz` column (C3).
`meeting_tz` beyond the design doc is decision C3. Nullable `client_id`/`project_id` follow the
`Option` + `nullif` handling Phase A established for `engineer_location.region`.

## Concept layout

Same per-concept CQRS shape as `location/`:

```
server/src/tempo/server/meeting/
  command.gleam      # writes: schedule / reschedule / cancel / add-attendee / remove-attendee
  view.gleam         # reads: upcoming list + per-attendee local times
  http.gleam         # GET /api/meetings?as_of=
  sql/*.sql          # + generated sql.gleam (migrate → squirrel)
shared/src/shared/meeting/
  command.gleam      # MeetingCommand union + encode + decoder (mirror location/command.gleam)
  view.gleam         # MeetingRecord + AttendeeRecord + JSON codecs
```

## Commands & write seam

All writes go through `POST /api/operations` → `command.dispatch` (authorizes via
`shared/access/policy`, one transaction) → the concept `route` returns
`Recorded(entry: Event(operation, summary, payload), facts: [...])` → `repository.record_facts`
appends the `event_log` row and threads its minted `id` as `audit_id`. Gated by `meeting.manage`.

`shared/meeting/command.gleam` — `MeetingCommand` union (mirror `LocationCommand`'s encode/decoder,
tagged by `op`):

| Command | Payload | Server action |
|---|---|---|
| `ScheduleMeeting` | title, timezone, date, `starts_at` (HH:MM), `duration_minutes`, location?, client_id?, project_id?, `attendees: List(#(Int, Attendance))` | INSERT `meeting`, `meeting_detail`, N `meeting_attendee`; compose `meeting_at` (below) |
| `RescheduleMeeting` | meeting_id, timezone, date, `starts_at`, `duration_minutes` | `UPDATE meeting_detail SET meeting_at, meeting_tz` |
| `CancelMeeting` | meeting_id | `UPDATE meeting_detail SET status = 'cancelled'` |
| `AddAttendee` | meeting_id, engineer_id, attendance | INSERT `meeting_attendee` (idempotent upsert on PK) |
| `RemoveAttendee` | meeting_id, engineer_id | DELETE `meeting_attendee` |

`Attendance` is a `Required | Optional` type in `shared/meeting/command.gleam` (not a bare string —
follows the "enumerate the statuses" house rule).

**Composing `meeting_at`** from (date, starts_at, duration, timezone) in SQL:

```sql
-- lower bound: the wall-clock instant in the chosen tz; upper: + duration
tstzrange(
  ((($date::text || ' ' || $starts_at::text)::timestamp) AT TIME ZONE $timezone),
  ((($date::text || ' ' || $starts_at::text)::timestamp) AT TIME ZONE $timezone)
    + ($duration_minutes::text || ' minutes')::interval,
  '[)')
```

`AT TIME ZONE $tz` on a naive timestamp yields a `timestamptz` — the same DST-correct primitive
Phase A proved. `meeting_tz` is validated against `pg_timezone_names` before the write (reuse the
`timezone_valid.sql` pattern from `location/`).

**Exhaustive wiring sites** (compiler-named; clean-build after adding the union variant):
- `shared`: `Command` union arm `MeetingCommand(MeetingCommand)` + `encode_command` + `grouped_command_decoder`
- `access/policy`: `CommandKey` `ManageMeeting` + `requirement` (`Direct(access.meeting_manage)`) + `key` (`MeetingCommand(_) -> ManageMeeting`)
- `shared/access.gleam`: `pub const meeting_manage = "meeting.manage"` + add to the grant list
- `rbac_seed.sql`: `meeting.manage` permission row + grant (mirror who holds `location.manage`)
- server: `auth.command_tag`, `command.dispatch_in` route to `meeting/command`, `fact.Fact`, `repository.write`

## Reads

`GET /api/meetings?as_of=` → `view.upcoming(ctx, as_of)` → upcoming **scheduled** meetings whose
`meeting_at` ends on or after the as-of instant, ordered by start. `MeetingRecord`:

```
MeetingRecord(
  id: Int,
  title: String,
  meeting_tz: String,
  starts_at: Timestamp,          // instant; client formats per-tz
  ends_at: Timestamp,
  canonical_offset_minutes: Int, // offset of meeting_tz at starts_at (Phase A offset primitive)
  location: Option(String),
  client_id: Option(Int),
  project_id: Option(Int),
  attendees: List(AttendeeRecord),
)

AttendeeRecord(
  engineer_id: Int,
  name: String,
  attendance: Attendance,
  timezone: Option(String),      // their engineer_location TZID as-of the date; None if unlocated
  local_offset_minutes: Option(Int),
)
```

Per-attendee timezone resolves via `engineer_location` as-of the date (the Phase A join); the
per-attendee offset reuses the Phase A Postgres offset expression
(`extract(epoch from ((instant AT TIME ZONE 'UTC') - (instant AT TIME ZONE tz)))/60`). An unlocated
attendee shows name + "no location" rather than a local time.

Squirrel nullability care (Phase A precedent): open-ended location ranges' `upper()` decodes as
non-null — select `coalesce(upper, lower)` + `upper_inf`; nullable INSERT params use `nullif($n,'')`.

The attendee **picker** fetches the existing `engineer_roster.sql` `(id, name)` list once and filters
client-side; no search endpoint is added.

## Create form (the bespoke piece)

The frozen `OpForm` record (`client/src/client/ui.gleam:591`) is all scalar `String` fields and
cannot hold a repeated attendee list. The repeating-group machinery that *does* exist
(`shared/workflow/schema.GroupField` + `client/workflow/render.group_view`) is bound to the workflow
draft/step/journal lifecycle and renders a bare number input for people — no autocomplete. So
`ScheduleMeeting`'s form is bespoke UI on the Calendar page (decision C6).

It holds a **typed** attendee model and mirrors `client/workflow/edit.gleam`'s row surgery
(add/remove/set — a copied *pattern*, ~40 lines, not the module):

```gleam
pub type Attendee { Attendee(engineer_id: Int, attendance: Attendance) }
// create-form model: List(Attendee); Msg: AttendeeAdded / AttendeeRemoved(index) / AttendanceSet(index, Attendance)
```

The row control is a purpose-built engineer autocomplete (client-side filter over the roster) plus a
required/optional select. On submit the form builds a `ScheduleMeeting` command directly and calls
`api.submit_operation` — it does not pass through `build_command`, keeping the op-form engine
scalar-only. `ScheduleMeeting` is therefore a `Command` variant but **not** an `OpKind`.

The four granular edits (C5/D-edits) add `OpKind`/`OpField` variants and reuse the flat engine:
reschedule reuses date/start/duration/tz fields; cancel is a confirm; add/remove attendee take
meeting_id + engineer_id (+ attendance).

## Client surface

New top-level **Calendar** nav page `client/src/client/page/calendar.gleam` — self-contained MVU with
the frozen `Model / Msg / init / update / view / refetch` interface; the shell owns the as-of date and
passes it into `refetch`. Permission gating mirrors the server via `shared/access/policy`.

- **Upcoming list** anchored to the as-of date: each row shows title, canonical time in `meeting_tz`
  (with its offset), and each attendee's local time; row actions edit / cancel gated by
  `meeting.manage`. Cancelled meetings drop off the list (D-cancel).
- **New meeting** launches the bespoke create form: title, tz picker (default = viewer's own location
  tz as-of the date), date, start, duration, optional location/client/project, and the attendee-list
  builder with the required/optional toggle.
- Local times render with the Phase A `client/time.utc_offset/1` helper and the per-attendee offsets
  from the read.

## Error handling

- **Invalid tz** → the `pg_timezone_names` check fails the write with a field prompt (Phase A pattern).
- **Empty/negative duration** → `build_command`/create-form validation rejects before submit; the DB
  `tstzrange` with `lower >= upper` would also be empty — guard client-side with a clear message.
- **Attendee not a current engineer / duplicate** → `meeting_attendee` PK + engineer FK reject;
  surface as an operation error.
- **Reschedule/cancel/add/remove on a missing meeting** → 404 via the standard operations error path.
- **Permission** → `meeting.manage` absent ⇒ 403 and the launcher/actions are hidden client-side.

## Testing

- **Server (`bin/test`, base seed):** command round-trips (schedule → read; reschedule moves the
  instant; cancel drops it from the upcoming read; add/remove attendee); tz→`tstzrange` composition
  across a DST boundary; `meeting.manage` gating (403 without); per-attendee offset math across a tz
  spread (e.g. Sydney vs London attendees) asserting exact offset ints.
- **Client:** create-form command building + validation (duration > 0, tz non-empty, ≥1 attendee);
  attendee add/remove/set-attendance state.
- **e2e (`bin/e2e`, demo seed + a couple of seeded meetings):** schedule a meeting with two attendees
  in different tzs; read each attendee's local time; reschedule and see the times move; cancel and see
  it leave the list. RBAC hide/show for the New-meeting launcher.
- **codec_test:** `MeetingCommand` encode/decode round-trip; `MeetingRecord`/`AttendeeRecord` JSON.

## Seed

Add to the base seed a small number of scheduled meetings referencing existing engineers whose
locations span timezones (reuse the Priya Sydney→London engineer so attendee-local-time assertions
are deterministic), plus the `meeting.manage` grant. The demo/e2e seed adds one project-linked meeting
for the e2e flow. Scenarios live in the seed and are safe to wipe and reseed.

## Out of scope (Phase D and later)

- The cross-timezone finder / find-a-time wizard, bulk attendee add ("everyone" / "from project"),
  booking concurrency (`SELECT … FOR UPDATE` + re-check) — all Phase D (#45).
- A calendar time-grid, recurring meetings, external calendar sync, notifications/invites.
- Availability inputs (`work_schedule`, `focus_block`, holidays) — Phase B (#43).
