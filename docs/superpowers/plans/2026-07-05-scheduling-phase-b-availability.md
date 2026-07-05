# Scheduling Phase B — Availability Inputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record everything the Phase D finder intersects and subtracts — per-weekday working hours (`work_schedule` temporal fact), personal focus blocks (plain mutable rows), and regional public holidays — with editing UI on the People detail page and a holidays section on the Locations page.

**Architecture:** A new `availability` concept (CQRS: `command.gleam` writes, `view.gleam` reads, `http.gleam`, `sql/*.sql`) split across `server/`, `shared/`, `client/`. `work_schedule` mirrors `engineer_location` (daterange `WITHOUT OVERLAPS`, set-from-date via `FOR PORTION OF`); `focus_block` and `holiday` mirror the Phase C meeting pattern (plain rows written as `fact.Fact` variants so the minted `audit_id` threads through `repository.write`). Schedule and focus writes use the `Owned` policy (`TakeLeave` precedent) so engineers manage their own availability; holiday import is `Direct`.

**Tech Stack:** Gleam (server=Erlang via pog/Wisp/Squirrel; shared+client=JavaScript via Lustre), PostgreSQL 18 (`FOR PORTION OF`, `WITHOUT OVERLAPS`), Playwright.

**Spec:** `docs/superpowers/specs/2026-07-05-scheduling-phase-b-availability-design.md`. **Templates:** `location` (temporal fact + FOR PORTION), `meeting` (plain-mutable + tstzrange composition + bespoke form), `leave` (Owned policy).

## Global Constraints

- **DB port:** export `TEMPO_DB_PORT=5435` for `bin/migrate`, `bin/test`, `bin/serve`, `bin/e2e`, `bin/squirrel`, `gleam test`. The 5434 default hangs.
- **migrate before squirrel:** `TEMPO_DB_PORT=5435 bin/migrate` then `TEMPO_DB_PORT=5435 bin/squirrel` (squirrel introspects the live DB).
- **Clean-build after adding a union variant:** `gleam clean && gleam build` in the affected project after adding a variant to `Command`, `Fact`, `CommandKey`, `OpKind`, `OpField` — incremental builds mask inexhaustive `case`.
- **Squirrel nullability gotchas:** an expression column (CASE, `extract`, `nullif`) defaults to NOT NULL in the generated row type even when it can be SQL NULL — force the nullable decoder by aliasing with a `?` suffix: `AS "offset_minutes?"` (Phase C precedent, commit c5419b0). A `$n::date` param binds a `calendar.Date`; a `$n::text`-cast param binds a `String`.
- **Seed "now" is 2026-06-15.** Server tests run on the base seed (`bin/test`, DB `tempo_test`); e2e runs base+financials (`bin/e2e`, DB `tempo_e2e`, rebuilds the client bundle first).
- **Test output:** never pipe a test/build runner through `head`/`tail`/`grep` in the same command; `… 2>&1 | tee /tmp/x.log` then inspect the file.
- **Gleam style:** `let assert Ok(...)` for Result unwrapping; `assert expr == expected` in tests; `todo` for stubs; NO inline comments in function bodies (only `////` module / `///` public-fn docs); descriptive names (no single letters beyond `i`/`acc`); `gleam format` before every commit.
- **String comparison:** Gleam's `<`/`>` are numeric only — compare `"HH:MM"` strings with `string.compare(a, b) == order.Lt`.
- **git:** stage explicit paths only; never stage `as-of-now.html` / `just-use-postgres.html`; commit messages describe WHAT + approach, no attribution footers.

---

## File Structure

**New files:**
- `server/priv/migrations/20260705150000_availability.sql` — four tables + `engineer_location` region normalization + FK.
- `server/src/tempo/server/availability/sql/*.sql` (10 files) + generated `server/src/tempo/server/availability/sql.gleam`.
- `server/src/tempo/server/availability/command.gleam` — routes `AvailabilityCommand` to `Recorded` facts.
- `server/src/tempo/server/availability/view.gleam` — per-engineer availability fold + holidays listing.
- `server/src/tempo/server/availability/http.gleam` — `GET /api/engineers/:id/availability`, `GET /api/holidays`.
- `shared/src/shared/availability/command.gleam` — `AvailabilityCommand` + `DayHours` + `HolidayRow` + codecs.
- `shared/src/shared/availability/view.gleam` — `AvailabilityRecord` / `DaySlot` / `FocusBlockRecord` / `EngineerHoliday` / `HolidayListing` + codecs.
- `server/test/availability_test.gleam` — dispatch-level integration tests.
- `client/test/availability_form_test.gleam` — weekly-grid builder + focus op builders + holiday paste parser tests.
- `e2e/availability.spec.js` — Playwright flow.

**Modified (exhaustive wiring):** `shared/command.gleam`, `shared/access.gleam`, `shared/access/policy.gleam` (incl. `target`), `server/.../fact.gleam`, `server/.../repository.gleam`, `server/.../auth.gleam`, `server/.../command.gleam`, `server/.../web/router.gleam`, `server/.../location/sql/*.sql` (region nullif rework), `client/.../ui.gleam`, `client/.../page/people/detail.gleam`, `client/.../page/locations.gleam`, `server/priv/seed/base_seed.sql`, `server/priv/seed/rbac_seed.sql`, `server/test/codec_test.gleam`, `server/test/auth_test.gleam`, `server/test/api_test.gleam`.

---

## Data model reference (used across tasks)

Weekday numbering: **0 = Monday … 6 = Sunday** (matches the umbrella design doc).

`focus_block.busy_at` composes exactly like Phase C's `meeting_at`:
```sql
tstzrange(
  (($date::text || ' ' || $starts_at::text)::timestamp AT TIME ZONE $timezone),
  (($date::text || ' ' || $starts_at::text)::timestamp AT TIME ZONE $timezone)
    + ($duration_minutes::text || ' minutes')::interval,
  '[)')
```

UTC offset (minutes east) of zone `tz` at instant `t`:
```sql
((extract(epoch from (t AT TIME ZONE tz)) - extract(epoch from (t AT TIME ZONE 'UTC'))) / 60)::int
```

Instants cross the wire as ISO-8601 UTC strings: `to_char(x AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`. Times of day cross as `"HH:MM"` strings (`to_char(starts, 'HH24:MI')`).

`holiday_region.region = ''` means nationwide. `engineer_location.region` becomes `NOT NULL DEFAULT ''` in the DB while the wire keeps `Option(String)` via `nullif(region, '') AS "region?"` in the read SQL.

---

### Task 1: Schema migration + availability SQL + location SQL rework + Squirrel regen

**Files:**
- Create: `server/priv/migrations/20260705150000_availability.sql`
- Create: `server/src/tempo/server/availability/sql/work_schedule_upsert.sql`
- Create: `server/src/tempo/server/availability/sql/work_schedule_clear.sql`
- Create: `server/src/tempo/server/availability/sql/work_schedule_asof.sql`
- Create: `server/src/tempo/server/availability/sql/focus_block_insert.sql`
- Create: `server/src/tempo/server/availability/sql/focus_block_delete.sql`
- Create: `server/src/tempo/server/availability/sql/focus_blocks_upcoming.sql`
- Create: `server/src/tempo/server/availability/sql/holiday_upsert.sql`
- Create: `server/src/tempo/server/availability/sql/holiday_region_exists.sql`
- Create: `server/src/tempo/server/availability/sql/holidays_for_engineer.sql`
- Create: `server/src/tempo/server/availability/sql/holidays_upcoming.sql`
- Create: `server/src/tempo/server/availability/sql/timezone_valid.sql`
- Modify: `server/src/tempo/server/location/sql/engineer_location_upsert.sql`, `engineer_locations_asof.sql`, `engineer_location_history.sql` (and any other location `.sql` selecting `region` — grep first)
- Generated: `server/src/tempo/server/availability/sql.gleam`, regenerated `server/src/tempo/server/location/sql.gleam`

**Interfaces:**
- Produces (generated `availability/sql.gleam`, consumed by Tasks 2 & 4): `work_schedule_upsert(db, engineer_id: Int, weekday: Int, effective: Date, starts: String, ends: String, audit_id: Int)`, `work_schedule_clear(db, engineer_id, weekday, effective: Date)`, `work_schedule_asof(db, engineer_id, as_of: Date)`, `focus_block_insert(db, engineer_id, date: String, starts_at: String, duration_minutes: String, timezone: String, title: String, audit_id)`, `focus_block_delete(db, focus_block_id, engineer_id)`, `focus_blocks_upcoming(db, engineer_id, as_of: Date)`, `holiday_upsert(db, country, region, holiday_on: Date, name, audit_id)`, `holiday_region_exists(db, country, region)`, `holidays_for_engineer(db, engineer_id, as_of: Date)`, `holidays_upcoming(db, as_of: Date)`, `timezone_valid(db, timezone)`. (Exact arg order follows `$1..$N`; verify the generated signatures — text-cast params come out `String`, `::date` params come out `Date`.)
- The regenerated `location/sql.gleam` keeps `region: Option(String)` in read rows (the `"region?"` alias) and `engineer_location_upsert` keeps accepting the region string (`''` = none).

- [ ] **Step 1: Verify the FK backfill covers every seeded region.**

Run:
```bash
grep -o "'[A-Z][A-Z]-[A-Z]\+'" server/priv/seed/base_seed.sql | sort -u
grep -rn "engineer_location" server/src/tempo/seed_financials.gleam | wc -l
```
Expected: regions ⊆ {AU-NSW, GB-LND, US-CA}; the financials seed has 0 `engineer_location` references. If a new region appears, add its `holiday_region` row to the migration's backfill INSERT below.

- [ ] **Step 2: Write the migration.**

Create `server/priv/migrations/20260705150000_availability.sql`:

```sql
-- 20260705150000_availability.sql — Phase B availability inputs. work_schedule is a
-- per-weekday temporal fact (FOR PORTION set-from-date, like engineer_location);
-- focus_block and holiday are plain rows carrying only audit_id (the Phase C meeting
-- pattern). holiday_region.region uses '' for nationwide so the composite PK and every
-- FK stay enforced; engineer_location.region is normalized to '' and gains the FK.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE holiday_region (
  country text NOT NULL,
  region  text NOT NULL DEFAULT '',
  name    text NOT NULL,
  PRIMARY KEY (country, region)
);

CREATE TABLE holiday (
  country    text   NOT NULL,
  region     text   NOT NULL DEFAULT '',
  holiday_on date   NOT NULL,
  name       text   NOT NULL,
  audit_id   bigint NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (country, region, holiday_on),
  FOREIGN KEY (country, region) REFERENCES holiday_region (country, region)
);
CREATE INDEX holiday_audit_id_idx ON holiday (audit_id);

CREATE TABLE work_schedule (
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  weekday     int       NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  valid_at    daterange NOT NULL,
  starts      time      NOT NULL,
  ends        time      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id),
  CHECK (starts < ends),
  PRIMARY KEY (engineer_id, weekday, valid_at WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX work_schedule_audit_id_idx ON work_schedule (audit_id);

CREATE TABLE focus_block (
  id          bigint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  busy_at     tstzrange NOT NULL,
  title       text      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id)
);
CREATE INDEX focus_block_audit_id_idx ON focus_block (audit_id);
CREATE INDEX focus_block_busy_gist ON focus_block USING gist (engineer_id, busy_at);

INSERT INTO holiday_region (country, region, name) VALUES
  ('AU', '', 'Australia'), ('AU', 'AU-NSW', 'New South Wales'),
  ('US', '', 'United States'), ('US', 'US-CA', 'California'),
  ('GB', '', 'United Kingdom'), ('GB', 'GB-LND', 'London');

UPDATE engineer_location SET region = '' WHERE region IS NULL;
ALTER TABLE engineer_location
  ALTER COLUMN region SET NOT NULL,
  ALTER COLUMN region SET DEFAULT '';
ALTER TABLE engineer_location
  ADD FOREIGN KEY (country, region) REFERENCES holiday_region (country, region);
```

- [ ] **Step 3: Rework the location SQL for the NOT NULL region.**

`grep -l region server/src/tempo/server/location/sql/*.sql` and adjust every hit:
- `engineer_location_upsert.sql`: change `nullif($4, '')` to `$4` (the DB now stores `''`).
- Every read selecting `region` (`engineer_locations_asof.sql`, `engineer_location_history.sql`, any roster query): change `region` in the SELECT list to `nullif(region, '') AS "region?"` so the wire type stays `Option(String)`.

- [ ] **Step 4: Write the write-side availability SQL.**

`server/src/tempo/server/availability/sql/work_schedule_upsert.sql`:
```sql
-- work_schedule_upsert.sql — set one weekday's hours from a date. $1 engineer_id,
-- $2 weekday (0=Mon), $3 effective, $4 starts (HH:MM), $5 ends (HH:MM), $6 audit_id.
WITH deleted AS (
  DELETE FROM work_schedule
     FOR PORTION OF valid_at FROM $3::date TO NULL
   WHERE engineer_id = $1 AND weekday = $2
)
INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), ($4::text)::time, ($5::text)::time, $6);
```

`server/src/tempo/server/availability/sql/work_schedule_clear.sql`:
```sql
-- work_schedule_clear.sql — clear one weekday's hours from a date. $1 engineer_id,
-- $2 weekday, $3 effective.
DELETE FROM work_schedule
   FOR PORTION OF valid_at FROM $3::date TO NULL
 WHERE engineer_id = $1 AND weekday = $2;
```

`server/src/tempo/server/availability/sql/focus_block_insert.sql`:
```sql
-- focus_block_insert.sql — add a focus block. $1 engineer_id, $2 date, $3 starts (HH:MM),
-- $4 duration_minutes, $5 timezone, $6 title, $7 audit_id.
INSERT INTO focus_block (engineer_id, busy_at, title, audit_id)
VALUES ($1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $6, $7);
```

`server/src/tempo/server/availability/sql/focus_block_delete.sql`:
```sql
-- focus_block_delete.sql — drop a focus block its claimed owner holds. $1 focus_block_id,
-- $2 engineer_id. RETURNING gates a missing or foreign block.
DELETE FROM focus_block WHERE id = $1 AND engineer_id = $2 RETURNING id;
```

`server/src/tempo/server/availability/sql/holiday_upsert.sql`:
```sql
-- holiday_upsert.sql — import one holiday row. $1 country, $2 region ('' = nationwide),
-- $3 date, $4 name, $5 audit_id. Re-import refreshes the name.
INSERT INTO holiday (country, region, holiday_on, name, audit_id)
VALUES ($1, $2, $3::date, $4, $5)
ON CONFLICT (country, region, holiday_on)
DO UPDATE SET name = EXCLUDED.name, audit_id = EXCLUDED.audit_id;
```

`server/src/tempo/server/availability/sql/holiday_region_exists.sql`:
```sql
-- holiday_region_exists.sql — whether ($1, $2) names a known region. $1 country, $2 region.
SELECT EXISTS (SELECT 1 FROM holiday_region WHERE country = $1 AND region = $2) AS known;
```

`server/src/tempo/server/availability/sql/timezone_valid.sql`:
```sql
-- timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1) AS valid;
```

- [ ] **Step 5: Write the read-side availability SQL.**

`server/src/tempo/server/availability/sql/work_schedule_asof.sql`:
```sql
-- work_schedule_asof.sql — one engineer's weekday hours covering $2. $1 engineer_id, $2 as_of.
SELECT weekday,
       to_char(starts, 'HH24:MI') AS starts,
       to_char(ends, 'HH24:MI') AS ends
FROM work_schedule
WHERE engineer_id = $1 AND valid_at @> $2::date
ORDER BY weekday;
```

`server/src/tempo/server/availability/sql/focus_blocks_upcoming.sql`:
```sql
-- focus_blocks_upcoming.sql — one engineer's focus blocks ending on/after $2, with the
-- block's UTC offset in the engineer's location timezone as-of $2 (NULL when unlocated).
-- $1 engineer_id, $2 as_of.
SELECT f.id AS id,
       f.title AS title,
       to_char(lower(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       ((extract(epoch from (lower(f.busy_at) AT TIME ZONE loc.timezone))
         - extract(epoch from (lower(f.busy_at) AT TIME ZONE 'UTC'))) / 60)::int AS "offset_minutes?"
FROM focus_block f
LEFT JOIN engineer_location loc
       ON loc.engineer_id = f.engineer_id AND loc.located_during @> $2::date
WHERE f.engineer_id = $1 AND upper(f.busy_at) >= $2::date
ORDER BY lower(f.busy_at), f.id;
```

`server/src/tempo/server/availability/sql/holidays_for_engineer.sql`:
```sql
-- holidays_for_engineer.sql — next 10 holidays for the engineer's location as-of $2;
-- nationwide ('') and subdivision rows both match. $1 engineer_id, $2 as_of.
SELECT h.holiday_on AS holiday_on, h.name AS name
FROM engineer_location loc
JOIN holiday h ON h.country = loc.country AND h.region IN ('', loc.region)
WHERE loc.engineer_id = $1 AND loc.located_during @> $2::date
  AND h.holiday_on >= $2::date
ORDER BY h.holiday_on
LIMIT 10;
```

`server/src/tempo/server/availability/sql/holidays_upcoming.sql`:
```sql
-- holidays_upcoming.sql — all holidays on/after $1 with their region names. $1 as_of.
SELECT h.country AS country, h.region AS region, r.name AS region_name,
       h.holiday_on AS holiday_on, h.name AS name
FROM holiday h
JOIN holiday_region r ON r.country = h.country AND r.region = h.region
WHERE h.holiday_on >= $1::date
ORDER BY h.holiday_on, h.country, h.region;
```

- [ ] **Step 6: Migrate and regenerate typed SQL.**

Run:
```bash
TEMPO_DB_PORT=5435 bin/migrate 2>&1 | tee /tmp/av-migrate.log
TEMPO_DB_PORT=5435 bin/squirrel 2>&1 | tee /tmp/av-squirrel.log
```
Expected: migration applies; squirrel regenerates. Inspect `server/src/tempo/server/availability/sql.gleam`: `focus_blocks_upcoming` row has `offset_minutes: Option(Int)`; `work_schedule_asof` row has `starts: String`, `ends: String`; `work_schedule_upsert` takes `Date` for `$3` and `String` for `$4`/`$5`; `focus_block_insert` takes `String` for `$2`–`$4`. Inspect regenerated `location/sql.gleam`: read rows keep `region: Option(String)`.

- [ ] **Step 7: Build + full server test (location tests must stay green).**

Run:
```bash
cd server && gleam build 2>&1 | tee /tmp/av-build.log
cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/test 2>&1 | tee /tmp/av-test1.log
```
Expected: compiles; every existing test passes (the location nullif rework is behaviour-preserving). If a location test fails on region encoding, re-check Step 3's `"region?"` aliases.

- [ ] **Step 8: Commit.**

```bash
git add server/priv/migrations/20260705150000_availability.sql server/src/tempo/server/availability/sql server/src/tempo/server/availability/sql.gleam server/src/tempo/server/location/sql server/src/tempo/server/location/sql.gleam
git commit -m "Add availability tables and typed SQL; normalize engineer_location.region with the holiday_region FK

work_schedule is a per-weekday temporal fact (FOR PORTION set-from-date); focus_block and holiday are plain rows with audit_id. holiday_region uses '' for nationwide so the composite PK and FKs stay enforced; location reads keep Option(String) on the wire via nullif + the \"region?\" alias."
```

---

### Task 2: Availability facts + repository write arms

**Files:**
- Modify: `server/src/tempo/server/fact.gleam`
- Modify: `server/src/tempo/server/repository.gleam`
- Test: `server/test/availability_test.gleam` (new)

**Interfaces:**
- Consumes: `availability/sql.gleam` from Task 1; `EngineerId`, `operation.run`, `operation.iso`, `require_covering_version` (repository.gleam:729).
- Produces (consumed by Task 3's `availability/command.gleam`): fact constructors
  `fact.WorkHoursSet(engineer_id: EngineerId, weekday: Int, from: Date, starts: String, ends: String)`,
  `fact.WorkDayCleared(engineer_id: EngineerId, weekday: Int, from: Date)`,
  `fact.FocusBlockAdded(engineer_id: EngineerId, date: Date, starts_at: String, duration_minutes: Int, timezone: String, title: String)`,
  `fact.FocusBlockRemoved(engineer_id: EngineerId, focus_block_id: Int)`,
  `fact.HolidayImported(country: String, region: String, holiday_on: Date, name: String)`.

- [ ] **Step 1: Add the five `Fact` variants.**

In `server/src/tempo/server/fact.gleam`, after the `MeetingAttendeeRemoved` arm (the current last `Fact` variant), add:

```gleam
  WorkHoursSet(
    engineer_id: EngineerId,
    weekday: Int,
    from: Date,
    starts: String,
    ends: String,
  )
  WorkDayCleared(engineer_id: EngineerId, weekday: Int, from: Date)
  FocusBlockAdded(
    engineer_id: EngineerId,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
    title: String,
  )
  FocusBlockRemoved(engineer_id: EngineerId, focus_block_id: Int)
  HolidayImported(country: String, region: String, holiday_on: Date, name: String)
```

- [ ] **Step 2: Clean-build to see the exhaustiveness failure (RED).**

Run: `cd server && gleam clean && gleam build 2>&1 | tee /tmp/av-fact.log`
Expected: FAIL — `repository.write`'s `case a_fact` misses the five new arms.

- [ ] **Step 3: Add the repository import and five write arms.**

In `server/src/tempo/server/repository.gleam`:
- Add `import tempo/server/availability/sql as availability_sql` beside the `location_sql`/`meeting_sql` imports.
- Add `WorkHoursSet, WorkDayCleared, FocusBlockAdded, FocusBlockRemoved, HolidayImported` to the `import tempo/server/fact.{…}` list.
- Add the arms inside `write`'s `case a_fact` (after the `MeetingAttendeeRemoved` arm):

```gleam
    WorkHoursSet(engineer_id: EngineerId(engineer_id), weekday:, from:, starts:, ends:) ->
      availability_sql.work_schedule_upsert(
        conn, engineer_id, weekday, from, starts, ends, audit_id,
      )
      |> operation.run

    WorkDayCleared(engineer_id: EngineerId(engineer_id), weekday:, from:) ->
      availability_sql.work_schedule_clear(conn, engineer_id, weekday, from)
      |> operation.run

    FocusBlockAdded(
      engineer_id: EngineerId(engineer_id),
      date:,
      starts_at:,
      duration_minutes:,
      timezone:,
      title:,
    ) ->
      availability_sql.focus_block_insert(
        conn,
        engineer_id,
        operation.iso(date),
        starts_at,
        int.to_string(duration_minutes),
        timezone,
        title,
        audit_id,
      )
      |> operation.run

    FocusBlockRemoved(engineer_id: EngineerId(engineer_id), focus_block_id:) ->
      availability_sql.focus_block_delete(conn, focus_block_id, engineer_id)
      |> require_covering_version

    HolidayImported(country:, region:, holiday_on:, name:) ->
      availability_sql.holiday_upsert(conn, country, region, holiday_on, name, audit_id)
      |> operation.run
```

(Adjust each call's argument order/types to the exact generated signatures from Task 1 Step 6 — `from`/`holiday_on` pass as `Date`, `date` passes as `operation.iso(date)` because `focus_block_insert`'s `$2` is text-cast. `import gleam/int` if absent.)

- [ ] **Step 4: Build to green, then write the audit-free repository test.**

Run: `cd server && gleam build 2>&1 | tee /tmp/av-fact2.log` — expect PASS.

Create `server/test/availability_test.gleam` (mirror `meeting_test.gleam`'s `rolling_back` + `insert_engineer` helpers — copy their bodies):

```gleam
import gleam/time/calendar.{Date, July}
import pog
import tempo/server/fact.{EngineerId, WorkDayCleared}
import tempo/server/repository
import tempo/server/test_pool

pub fn clearing_an_empty_weekday_succeeds_test() {
  use conn <- rolling_back()
  let engineer_id = insert_engineer(conn)
  let outcome =
    repository.write(
      conn,
      1,
      WorkDayCleared(
        engineer_id: EngineerId(engineer_id),
        weekday: 4,
        from: Date(2026, July, 1),
      ),
    )
  assert outcome == Ok(Nil)
}
```

(`WorkDayCleared` is the only fact with no `audit_id` INSERT, so it needs no `event_log` row; the other four are covered by Task 3's `dispatch_in` tests where `record_facts` mints a real event id. Copy `rolling_back`/`insert_engineer` verbatim from `server/test/meeting_test.gleam:13-30`.)

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/av-repo.log` — expect PASS.

- [ ] **Step 5: Commit.**

```bash
git add server/src/tempo/server/fact.gleam server/src/tempo/server/repository.gleam server/test/availability_test.gleam
git commit -m "Record availability writes as facts threaded with audit_id

WorkHoursSet/WorkDayCleared map to the FOR PORTION weekday upsert/clear; FocusBlockAdded/Removed and HolidayImported map to plain INSERT/DELETE/upsert. Removing a foreign or missing focus block gates via require_covering_version."
```

---

### Task 3: Shared command contract + Owned policy + dispatch wiring

**Files:**
- Create: `shared/src/shared/availability/command.gleam`
- Create: `server/src/tempo/server/availability/command.gleam`
- Modify: `shared/src/shared/command.gleam`, `shared/src/shared/access.gleam`, `shared/src/shared/access/policy.gleam`
- Modify: `server/src/tempo/server/auth.gleam`, `server/src/tempo/server/command.gleam`
- Modify: `server/test/codec_test.gleam`, `server/test/auth_test.gleam`, `server/test/availability_test.gleam`

**Interfaces:**
- Consumes: Task 2 fact constructors; `availability/sql.{timezone_valid, holiday_region_exists}`.
- Produces (consumed by client Tasks 5–7):
  `shared/availability/command.gleam` public API —
  `type DayHours { DayHours(weekday: Int, hours: Option(#(String, String))) }`,
  `type HolidayRow { HolidayRow(country: String, region: String, holiday_on: Date, name: String) }`,
  `type AvailabilityCommand { SetWorkSchedule(engineer_id: Int, effective: Date, days: List(DayHours))  AddFocusBlock(engineer_id: Int, date: Date, starts_at: String, duration_minutes: Int, timezone: String, title: String)  RemoveFocusBlock(engineer_id: Int, focus_block_id: Int)  ImportHolidays(rows: List(HolidayRow)) }`,
  `encode(AvailabilityCommand) -> Json`, `decoder(op: String) -> Result(Decoder(AvailabilityCommand), Nil)`;
  policy keys `ManageAvailability` (`Owned`) and `ManageHolidays` (`Direct`); permission constants `access.availability_manage_own = "availability.manage.own"`, `access.availability_manage_any = "availability.manage.any"`, `access.holiday_manage = "holiday.manage"`.

- [ ] **Step 1: Write the shared command module.**

Create `shared/src/shared/availability/command.gleam`:

```gleam
//// Write commands for availability inputs: weekly working hours, focus blocks, and
//// public-holiday import. Each is tagged by `op` for the grouped command decoder.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type DayHours {
  DayHours(weekday: Int, hours: Option(#(String, String)))
}

pub type HolidayRow {
  HolidayRow(country: String, region: String, holiday_on: Date, name: String)
}

pub type AvailabilityCommand {
  SetWorkSchedule(engineer_id: Int, effective: Date, days: List(DayHours))
  AddFocusBlock(
    engineer_id: Int,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
    title: String,
  )
  RemoveFocusBlock(engineer_id: Int, focus_block_id: Int)
  ImportHolidays(rows: List(HolidayRow))
}

fn encode_day(day: DayHours) -> Json {
  let #(starts, ends) = case day.hours {
    Some(#(starts, ends)) -> #(Some(starts), Some(ends))
    None -> #(None, None)
  }
  json.object([
    #("weekday", json.int(day.weekday)),
    #("starts", json.nullable(starts, json.string)),
    #("ends", json.nullable(ends, json.string)),
  ])
}

fn day_decoder() -> Decoder(DayHours) {
  use weekday <- decode.field("weekday", decode.int)
  use starts <- decode.field("starts", decode.optional(decode.string))
  use ends <- decode.field("ends", decode.optional(decode.string))
  let hours = case starts, ends {
    Some(starts_value), Some(ends_value) -> Some(#(starts_value, ends_value))
    _, _ -> None
  }
  decode.success(DayHours(weekday:, hours:))
}

fn encode_holiday_row(row: HolidayRow) -> Json {
  json.object([
    #("country", json.string(row.country)),
    #("region", json.string(row.region)),
    #("holiday_on", encode_date(row.holiday_on)),
    #("name", json.string(row.name)),
  ])
}

fn holiday_row_decoder() -> Decoder(HolidayRow) {
  use country <- decode.field("country", decode.string)
  use region <- decode.field("region", decode.string)
  use holiday_on <- decode.field("holiday_on", date_decoder())
  use name <- decode.field("name", decode.string)
  decode.success(HolidayRow(country:, region:, holiday_on:, name:))
}

pub fn encode(command: AvailabilityCommand) -> Json {
  case command {
    SetWorkSchedule(engineer_id:, effective:, days:) ->
      json.object([
        #("op", json.string("set_work_schedule")),
        #("engineer_id", json.int(engineer_id)),
        #("effective", encode_date(effective)),
        #("days", json.array(days, encode_day)),
      ])
    AddFocusBlock(engineer_id:, date:, starts_at:, duration_minutes:, timezone:, title:) ->
      json.object([
        #("op", json.string("add_focus_block")),
        #("engineer_id", json.int(engineer_id)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
        #("timezone", json.string(timezone)),
        #("title", json.string(title)),
      ])
    RemoveFocusBlock(engineer_id:, focus_block_id:) ->
      json.object([
        #("op", json.string("remove_focus_block")),
        #("engineer_id", json.int(engineer_id)),
        #("focus_block_id", json.int(focus_block_id)),
      ])
    ImportHolidays(rows:) ->
      json.object([
        #("op", json.string("import_holidays")),
        #("rows", json.array(rows, encode_holiday_row)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(AvailabilityCommand), Nil) {
  case op {
    "set_work_schedule" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        use days <- decode.field("days", decode.list(day_decoder()))
        decode.success(SetWorkSchedule(engineer_id:, effective:, days:))
      })
    "add_focus_block" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        use timezone <- decode.field("timezone", decode.string)
        use title <- decode.field("title", decode.string)
        decode.success(AddFocusBlock(
          engineer_id:,
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          title:,
        ))
      })
    "remove_focus_block" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use focus_block_id <- decode.field("focus_block_id", decode.int)
        decode.success(RemoveFocusBlock(engineer_id:, focus_block_id:))
      })
    "import_holidays" ->
      Ok({
        use rows <- decode.field("rows", decode.list(holiday_row_decoder()))
        decode.success(ImportHolidays(rows:))
      })
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 2: Wire into the shared `Command` union.**

In `shared/src/shared/command.gleam`:
- Import (alphabetical): `import shared/availability/command as availability_command`
- Union arm: `AvailabilityCommand(availability_command.AvailabilityCommand)`
- `encode_command` arm: `AvailabilityCommand(command) -> availability_command.encode(command)`
- In `grouped_command_decoder` before `Error(Nil)` (shared/command.gleam:141): `use <- try_group(availability_command.decoder(op), AvailabilityCommand)`

- [ ] **Step 3: Permissions + policy (incl. the ownership target).**

In `shared/src/shared/access.gleam`:
- After `pub const meeting_manage` (line 85):
```gleam
pub const availability_manage_own = "availability.manage.own"

pub const availability_manage_any = "availability.manage.any"

pub const holiday_manage = "holiday.manage"
```
- Append `availability_manage_own, availability_manage_any, holiday_manage,` to `all()`.

In `shared/src/shared/access/policy.gleam`:
- Import: `import shared/availability/command as availability_command` and add `AvailabilityCommand` to the `Command`-variant import list.
- `CommandKey`: add `ManageAvailability` and `ManageHolidays` after `ManageMeeting`.
- `requirement`: `ManageAvailability -> Owned(access.availability_manage_own, access.availability_manage_any)` and `ManageHolidays -> Direct(access.holiday_manage)`.
- `key`:
```gleam
    AvailabilityCommand(availability_command.ImportHolidays(_)) -> ManageHolidays
    AvailabilityCommand(_) -> ManageAvailability
```
- `target` (policy.gleam:130-137) — add before the `_ -> None` arm:
```gleam
    AvailabilityCommand(availability) -> availability_target(availability)
```
and the helper beside `timesheet_target`:
```gleam
fn availability_target(command: availability_command.AvailabilityCommand) -> Option(Int) {
  case command {
    availability_command.SetWorkSchedule(engineer_id:, ..) -> Some(engineer_id)
    availability_command.AddFocusBlock(engineer_id:, ..) -> Some(engineer_id)
    availability_command.RemoveFocusBlock(engineer_id:, ..) -> Some(engineer_id)
    availability_command.ImportHolidays(_) -> None
  }
}
```
(Match `target`'s actual return shape — if it returns `Option(Int)` directly, the arm is `AvailabilityCommand(availability) -> availability_target(availability)`; if it wraps in `Some(...)` per-aggregate, mirror `timesheet_target`'s exact idiom.)

- [ ] **Step 4: Server auth tag + dispatch route.**

In `server/src/tempo/server/auth.gleam`: add `AvailabilityCommand` to the `Command`-variant import; `command_tag` arm: `AvailabilityCommand(_) -> "manage_availability"`.

In `server/src/tempo/server/command.gleam`: add `AvailabilityCommand` to the import; `import tempo/server/availability/command as availability` beside the `meeting` alias (line 44); `route` arm: `AvailabilityCommand(command) -> availability.route(conn, command)`.

- [ ] **Step 5: Write the server command handler.**

Create `server/src/tempo/server/availability/command.gleam`:

```gleam
//// Write handler for availability. set_work_schedule validates the 7-day grid and fans
//// out one fact per weekday; add_focus_block validates the TZID; import_holidays checks
//// every region against the reference table before upserting.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import pog
import shared/availability/command.{
  type AvailabilityCommand, type DayHours, type HolidayRow, AddFocusBlock,
  ImportHolidays, RemoveFocusBlock, SetWorkSchedule,
}
import shared/command as gateway
import tempo/server/availability/sql as availability_sql
import tempo/server/fact.{
  type Recorded, EngineerId, FocusBlockAdded, FocusBlockRemoved, HolidayImported,
  Recorded, WorkDayCleared, WorkHoursSet,
}
import tempo/server/operation.{type OperationError, Event}

/// Route an availability command to its operation. Exhaustive over
/// `AvailabilityCommand`.
pub fn route(
  conn: pog.Connection,
  command: AvailabilityCommand,
) -> Result(Recorded, OperationError) {
  case command {
    SetWorkSchedule(engineer_id:, effective:, days:) ->
      set_work_schedule(command, engineer_id:, effective:, days:)
    AddFocusBlock(engineer_id:, date:, starts_at:, duration_minutes:, timezone:, title:) ->
      add_focus_block(
        conn,
        command,
        engineer_id:,
        date:,
        starts_at:,
        duration_minutes:,
        timezone:,
        title:,
      )
    RemoveFocusBlock(engineer_id:, focus_block_id:) ->
      Ok(remove_focus_block(command, engineer_id:, focus_block_id:))
    ImportHolidays(rows:) -> import_holidays(conn, command, rows)
  }
}

fn valid_time(raw: String) -> Bool {
  case string.split(raw, ":") {
    [hour_text, minute_text] ->
      case int.parse(hour_text), int.parse(minute_text) {
        Ok(hour), Ok(minute) ->
          string.length(hour_text) == 2
          && string.length(minute_text) == 2
          && hour >= 0
          && hour <= 23
          && minute >= 0
          && minute <= 59
        _, _ -> False
      }
    _ -> False
  }
}

fn day_valid(day: DayHours) -> Bool {
  case day.hours {
    None -> True
    Some(#(starts, ends)) ->
      valid_time(starts)
      && valid_time(ends)
      && string.compare(starts, ends) == order.Lt
  }
}

fn week_valid(days: List(DayHours)) -> Bool {
  let weekdays =
    days |> list.map(fn(day) { day.weekday }) |> list.sort(int.compare)
  weekdays == [0, 1, 2, 3, 4, 5, 6] && list.all(days, day_valid)
}

fn set_work_schedule(
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  effective effective: Date,
  days days: List(DayHours),
) -> Result(Recorded, OperationError) {
  case week_valid(days) {
    False -> Error(operation.InvalidValue)
    True -> {
      let facts =
        list.map(days, fn(day) {
          case day.hours {
            Some(#(starts, ends)) ->
              WorkHoursSet(
                engineer_id: EngineerId(engineer_id),
                weekday: day.weekday,
                from: effective,
                starts:,
                ends:,
              )
            None ->
              WorkDayCleared(
                engineer_id: EngineerId(engineer_id),
                weekday: day.weekday,
                from: effective,
              )
          }
        })
      Ok(Recorded(
        entry: Event(
          operation: "set_work_schedule",
          summary: "Set weekly hours for engineer "
            <> int.to_string(engineer_id)
            <> " from "
            <> operation.iso(effective),
          payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
        ),
        facts:,
      ))
    }
  }
}

fn add_focus_block(
  conn: pog.Connection,
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  date date: Date,
  starts_at starts_at: String,
  duration_minutes duration_minutes: Int,
  timezone timezone: String,
  title title: String,
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(availability_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid && valid_time(starts_at) && duration_minutes > 0 {
    False -> Error(operation.InvalidValue)
    True ->
      Ok(Recorded(
        entry: Event(
          operation: "add_focus_block",
          summary: "Added focus block \""
            <> title
            <> "\" for engineer "
            <> int.to_string(engineer_id)
            <> " on "
            <> operation.iso(date),
          payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
        ),
        facts: [
          FocusBlockAdded(
            engineer_id: EngineerId(engineer_id),
            date:,
            starts_at:,
            duration_minutes:,
            timezone:,
            title:,
          ),
        ],
      ))
  }
}

fn remove_focus_block(
  command: AvailabilityCommand,
  engineer_id engineer_id: Int,
  focus_block_id focus_block_id: Int,
) -> Recorded {
  Recorded(
    entry: Event(
      operation: "remove_focus_block",
      summary: "Removed focus block "
        <> int.to_string(focus_block_id)
        <> " for engineer "
        <> int.to_string(engineer_id),
      payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
    ),
    facts: [
      FocusBlockRemoved(
        engineer_id: EngineerId(engineer_id),
        focus_block_id:,
      ),
    ],
  )
}

fn import_holidays(
  conn: pog.Connection,
  command: AvailabilityCommand,
  rows: List(HolidayRow),
) -> Result(Recorded, OperationError) {
  case rows {
    [] -> Error(operation.InvalidValue)
    _ -> {
      use _ <- result.try(ensure_regions(conn, rows))
      Ok(Recorded(
        entry: Event(
          operation: "import_holidays",
          summary: "Imported "
            <> int.to_string(list.length(rows))
            <> " public holidays",
          payload: gateway.encode_command(gateway.AvailabilityCommand(command)),
        ),
        facts: list.map(rows, fn(row) {
          HolidayImported(
            country: row.country,
            region: row.region,
            holiday_on: row.holiday_on,
            name: row.name,
          )
        }),
      ))
    }
  }
}

fn ensure_regions(
  conn: pog.Connection,
  rows: List(HolidayRow),
) -> Result(Nil, OperationError) {
  case rows {
    [] -> Ok(Nil)
    [row, ..rest] -> {
      use known <- operation.try(availability_sql.holiday_region_exists(
        conn,
        row.country,
        row.region,
      ))
      let assert [check] = known.rows
      case check.known {
        True -> ensure_regions(conn, rest)
        False -> Error(operation.InvalidValue)
      }
    }
  }
}
```

(`result_try` = `gleam/result.try` — import `gleam/result` and use `result.try`, mirroring `meeting/command.gleam`. Verify the generated column names `check.valid` / `check.known` against `availability/sql.gleam`.)

- [ ] **Step 6: Clean-build all three targets.**

```bash
cd /Users/michaelbuhot/src/mbuhot/tempo/server && gleam clean && gleam build 2>&1 | tee /tmp/av-srv.log
cd /Users/michaelbuhot/src/mbuhot/tempo/shared && gleam build 2>&1 | tee /tmp/av-shr.log
cd /Users/michaelbuhot/src/mbuhot/tempo/client && gleam clean && gleam build 2>&1 | tee /tmp/av-cli.log
```
Expected: all compile. The client clean-build matters: `policy.CommandKey` gained variants and `ui.gleam` has `case CommandKey` sites in the permit path — if any is inexhaustive the clean build names it (resolve by adding arms mirroring `ManageMeeting`'s).

- [ ] **Step 7: Codec round-trip tests (RED then GREEN).**

In `server/test/codec_test.gleam` add `import shared/availability/command as availability_command` and:

```gleam
pub fn command_set_work_schedule_round_trips_test() {
  let original =
    gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
      engineer_id: 1,
      effective: Date(2026, July, 6),
      days: [
        availability_command.DayHours(0, Some(#("09:00", "17:00"))),
        availability_command.DayHours(1, Some(#("09:00", "17:00"))),
        availability_command.DayHours(2, Some(#("10:00", "16:00"))),
        availability_command.DayHours(3, Some(#("09:00", "17:00"))),
        availability_command.DayHours(4, None),
        availability_command.DayHours(5, None),
        availability_command.DayHours(6, None),
      ],
    ))
  assert round_trip(original, gateway.encode_command, gateway.command_decoder())
    == original
}

pub fn command_import_holidays_round_trips_test() {
  let original =
    gateway.AvailabilityCommand(availability_command.ImportHolidays(rows: [
      availability_command.HolidayRow("AU", "AU-NSW", Date(2026, October, 5), "Labour Day"),
      availability_command.HolidayRow("GB", "", Date(2026, August, 31), "Summer Bank Holiday"),
    ]))
  assert round_trip(original, gateway.encode_command, gateway.command_decoder())
    == original
}
```

(Import `Some`/`None` from `gleam/option` and the month constants used. Match the file's existing `round_trip` helper.)

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/av-codec.log` — expect PASS.

- [ ] **Step 8: Own-vs-any auth test.**

In `server/test/auth_test.gleam`, mirror `profile_update_is_ownership_scoped_test` (auth_test.gleam:89-97) with a helper building `gateway.AvailabilityCommand(availability_command.SetWorkSchedule(engineer_id: N, effective: Date(2026, July, 6), days: [...7 entries...]))`:

```gleam
pub fn availability_is_ownership_scoped_test() {
  let own_set = principal_with([access.availability_manage_own], Some(5))
  assert auth.authorize(own_set, set_schedule(5)) == Ok("Test")
  assert auth.authorize(own_set, set_schedule(9))
    == Error(Forbidden(actor: "Test", command: "manage_availability"))
  let any_set = principal_with([access.availability_manage_any], None)
  assert auth.authorize(any_set, set_schedule(9)) == Ok("Test")
}

pub fn holiday_import_requires_holiday_manage_test() {
  let no_permission = principal_with([access.availability_manage_any], None)
  assert auth.authorize(no_permission, import_one())
    == Error(Forbidden(actor: "Test", command: "manage_availability"))
  let holiday_admin = principal_with([access.holiday_manage], None)
  assert auth.authorize(holiday_admin, import_one()) == Ok("Test")
}
```

(`set_schedule(engineer_id)` and `import_one()` are small private constructors in the test file — write them with a full 7-day grid and one `HolidayRow`.)

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/av-auth.log` — expect PASS.

- [ ] **Step 9: Dispatch-level integration tests.**

Extend `server/test/availability_test.gleam` with `command.dispatch_in(conn, "tester", gateway.AvailabilityCommand(...))` tests (mirror `meeting_test.gleam`'s raw-SQL re-read helpers):
- set a 7-day week (Mon–Thu working, Fri–Sun off) → `work_schedule` has 4 rows for the engineer, each `valid_at @> effective`, `to_char(starts,'HH24:MI') == "09:00"`;
- re-set from a later date with different Monday hours → as-of the earlier date the old hours hold, as-of the later date the new hours hold (two eras from FOR PORTION);
- malformed grid (6 entries) and bad time (`"25:00"`) → `Error(operation.InvalidValue)`;
- add a focus block → a `focus_block` row exists with the composed range (`to_char(lower(busy_at) AT TIME ZONE $tz, 'HH24:MI')` equals the input) and non-null `audit_id`; unknown TZID → `InvalidValue`;
- remove it (matching engineer_id) → row gone; remove with a wrong engineer_id → `Error(operation.NoSuchVersion)`;
- import two holidays → rows exist; re-import one with a new name → name updated; import with unknown region `("FR","")` → `InvalidValue`.

Run: `cd server && TEMPO_DB_PORT=5435 gleam test 2>&1 | tee /tmp/av-disp.log` — expect PASS.

- [ ] **Step 10: Commit.**

```bash
git add shared/src/shared/availability/command.gleam shared/src/shared/command.gleam shared/src/shared/access.gleam shared/src/shared/access/policy.gleam server/src/tempo/server/availability/command.gleam server/src/tempo/server/auth.gleam server/src/tempo/server/command.gleam server/test/codec_test.gleam server/test/auth_test.gleam server/test/availability_test.gleam
git commit -m "Add AvailabilityCommand with Owned policy and route it to availability facts

SetWorkSchedule validates the 7-day grid and fans out per-weekday facts; AddFocusBlock validates the TZID; ImportHolidays pre-checks regions. availability.manage.own/.any mirror leave's ownership scoping via policy.target; holiday.manage gates import."
```

---

### Task 4: Read models, HTTP endpoints, router, and seed

**Files:**
- Create: `shared/src/shared/availability/view.gleam`
- Create: `server/src/tempo/server/availability/view.gleam`
- Create: `server/src/tempo/server/availability/http.gleam`
- Modify: `server/src/tempo/server/web/router.gleam`
- Modify: `server/priv/seed/base_seed.sql`, `server/priv/seed/rbac_seed.sql`
- Test: `server/test/api_test.gleam`

**Interfaces:**
- Consumes: Task 1 read SQL; `request.date_from_query`, `response.{json_response, db_error_response}`, `guard.require`.
- Produces (consumed by client Tasks 5–7): `shared/availability/view.gleam` —
  `type DaySlot { DaySlot(weekday: Int, starts: Option(String), ends: Option(String)) }`,
  `type FocusBlockRecord { FocusBlockRecord(id: Int, title: String, starts_at: String, ends_at: String, offset_minutes: Option(Int)) }`,
  `type EngineerHoliday { EngineerHoliday(holiday_on: Date, name: String) }`,
  `type AvailabilityRecord { AvailabilityRecord(week: List(DaySlot), focus_blocks: List(FocusBlockRecord), holidays: List(EngineerHoliday)) }`,
  `type HolidayListing { HolidayListing(country: String, region: String, region_name: String, holiday_on: Date, name: String) }`,
  encoders `encode_availability_record` / `encode_holiday_listing` and decoders `availability_record_decoder()` / `holiday_listing_decoder()` (field-for-field, `wire.encode_date`/`wire.date_decoder` for dates);
  endpoints `GET /api/engineers/:id/availability?as_of=` (one `AvailabilityRecord` object) and `GET /api/holidays?as_of=` (array of `HolidayListing`), both gated by `access.read_engineers`.

- [ ] **Step 1: Shared view types + codecs.**

Create `shared/src/shared/availability/view.gleam` with the five types above and paired `encode_*`/`*_decoder` functions in the `shared/meeting/view.gleam` style (`json.object` + `decode.field`; `Option` via `json.nullable`/`decode.optional`). `week` always carries exactly 7 `DaySlot`s, weekday order 0–6.

- [ ] **Step 2: Server view fold.**

Create `server/src/tempo/server/availability/view.gleam`:

```gleam
pub fn availability(
  context: Context,
  engineer_id: Int,
  as_of: Date,
) -> Result(AvailabilityRecord, pog.QueryError)

pub fn holidays(
  context: Context,
  as_of: Date,
) -> Result(List(HolidayListing), pog.QueryError)
```

`availability` runs `work_schedule_asof`, `focus_blocks_upcoming`, `holidays_for_engineer`, then builds `week` by mapping weekdays 0–6 to `DaySlot(weekday, Some(starts), Some(ends))` when a row exists and `DaySlot(weekday, None, None)` when it does not (build a `dict` from the rows keyed by weekday, then `list.map(list.range(0, 6), …)`). `holidays` maps `holidays_upcoming` rows straight across. Mirror `meeting/view.gleam`'s row→record mapping style.

- [ ] **Step 3: HTTP handlers.**

Create `server/src/tempo/server/availability/http.gleam` mirroring `location/http.gleam`:
- `handle_availability(req, ctx, id_segment: String)` — require `http.Get`; `int.parse(id_segment)` else `wisp.bad_request`; `request.date_from_query(req, "as_of")`; `view.availability` → `response.json_response(availability_view.encode_availability_record(record))`.
- `handle_holidays(req, ctx)` — require `http.Get`; `as_of` from query; `view.holidays` → `json.array(records, availability_view.encode_holiday_listing)`.

- [ ] **Step 4: Router arms.**

In `server/src/tempo/server/web/router.gleam`, import `tempo/server/availability/http as availability_http` and add before the `["api", ..]` catch-all (beside the location arms at router.gleam:203-210):

```gleam
    ["api", "engineers", id, "availability"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      availability_http.handle_availability(request, context, id)
    }
    ["api", "holidays"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      availability_http.handle_holidays(request, context)
    }
```

- [ ] **Step 5: Seed.**

In `server/priv/seed/rbac_seed.sql`:
- Permission catalog (extend the VALUES list ending at `meeting.manage`):
```sql
  ('availability.manage.own', 'Set one''s own working hours and focus blocks'),
  ('availability.manage.any', 'Set any engineer''s working hours and focus blocks'),
  ('holiday.manage', 'Import and maintain public holidays');
```
- Grants (mirror the leave rows' shape): `engineer` → `availability.manage.own`; `manager` → `availability.manage.any`; `owner` → `availability.manage.own`, `availability.manage.any`, `holiday.manage`.

In `server/priv/seed/base_seed.sql`, after the meeting seed block:
```sql
-- Seed availability (scheduling Phase B): default 9-17 Mon-Fri for all engineers,
-- Priya drops Fridays from 2026-07-01, one Marcus focus block, and 2026 holidays
-- for the three seeded regions.
WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2024-01-01', 'seed', 'set_work_schedule', 'Seed default 9-17 Mon-Fri for engineers 1-3', '{}')
  RETURNING id)
INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id)
SELECT eng.engineer_id, wd.weekday, daterange('2024-01-01', NULL, '[)'), '09:00'::time, '17:00'::time, e.id
FROM e,
     (VALUES (1), (2), (3)) AS eng(engineer_id),
     (VALUES (0), (1), (2), (3), (4)) AS wd(weekday);

INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
  ('2026-06-20', 'seed', 'set_work_schedule', 'Priya drops Fridays from 2026-07-01', '{}');
DELETE FROM work_schedule
   FOR PORTION OF valid_at FROM '2026-07-01' TO NULL
 WHERE engineer_id = 1 AND weekday = 4;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-06-10', 'seed', 'add_focus_block', 'Added focus block "Deep work: incident review" for engineer 2 on 2026-06-22', '{}')
  RETURNING id)
INSERT INTO focus_block (engineer_id, busy_at, title, audit_id)
SELECT 2,
  tstzrange(('2026-06-22 13:00'::timestamp AT TIME ZONE 'America/Los_Angeles'),
            ('2026-06-22 13:00'::timestamp AT TIME ZONE 'America/Los_Angeles') + interval '120 minutes', '[)'),
  'Deep work: incident review', e.id
FROM e;

WITH e AS (
  INSERT INTO event_log (occurred_at, actor, operation, summary, payload) VALUES
    ('2026-01-05', 'seed', 'import_holidays', 'Imported 5 public holidays for AU/US/GB 2026', '{}')
  RETURNING id)
INSERT INTO holiday (country, region, holiday_on, name, audit_id)
SELECT v.country, v.region, v.holiday_on::date, v.name, e.id
FROM e, (VALUES
  ('AU', '', '2026-12-25', 'Christmas Day'),
  ('AU', 'AU-NSW', '2026-10-05', 'Labour Day'),
  ('US', '', '2026-11-26', 'Thanksgiving'),
  ('US', 'US-CA', '2026-09-09', 'California Admission Day'),
  ('GB', '', '2026-08-31', 'Summer Bank Holiday')
) AS v(country, region, holiday_on, name);
```

Check `server/test/access_test.gleam` for a permission-count snapshot assertion (Phase C's count landed on 27) and bump it by 3.

- [ ] **Step 6: API tests (RED then GREEN).**

In `server/test/api_test.gleam` (mirror the meetings GET/403 tests at api_test.gleam:1466-1501 and the `decode_meetings` helper shape):
- `GET /api/engineers/1/availability?as_of=2026-07-05` → 200; decode one `AvailabilityRecord`; `week` has 7 slots; weekday 0 = `Some("09:00")`/`Some("17:00")`; weekday 4 = `None` (Priya's dropped Friday); weekday 5 and 6 = `None`; holidays include `"Summer Bank Holiday"` (Priya is GB as-of 2026-07-05).
- `GET /api/engineers/2/availability?as_of=2026-06-16` → Marcus's `focus_blocks` contains `"Deep work: incident review"` with `offset_minutes == Some(-420)`; his holidays include `"California Admission Day"` and `"Thanksgiving"`.
- `GET /api/holidays?as_of=2026-07-05` → 5 rows; the `2026-10-05` row has `region_name == "New South Wales"`.
- A permissionless principal on `/api/holidays` → 403 (mirror the existing 403 idiom).

Run: `cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/test 2>&1 | tee /tmp/av-api.log`
Expected: PASS (bin/test recreates `tempo_test` with the new seed; if it reports "already seeded", drop the DB first: `docker exec tempo-db psql -U tempo -c 'DROP DATABASE tempo_test WITH (FORCE)'` then re-run).

- [ ] **Step 7: Commit.**

```bash
git add shared/src/shared/availability/view.gleam server/src/tempo/server/availability/view.gleam server/src/tempo/server/availability/http.gleam server/src/tempo/server/web/router.gleam server/priv/seed/base_seed.sql server/priv/seed/rbac_seed.sql server/test/api_test.gleam server/test/access_test.gleam
git commit -m "Serve per-engineer availability and the holidays listing; seed defaults + permissions

GET /api/engineers/:id/availability folds the as-of weekly grid, upcoming focus blocks with location-tz offsets, and regional holidays; GET /api/holidays lists all upcoming with region names. Seeds default 9-17 Mon-Fri, Priya's dropped Friday, a Marcus focus block, and five 2026 holidays."
```

---

### Task 5: People-detail Availability panel + bespoke weekly editor

**Files:**
- Modify: `client/src/client/page/people/detail.gleam`
- Test: `client/test/availability_form_test.gleam` (new)

**Interfaces:**
- Consumes: `shared/availability/view.{AvailabilityRecord, availability_record_decoder}`; `shared/availability/command.{SetWorkSchedule, DayHours}`; `api.get`, `api.submit_operation`, `time.iso_date`; the page's existing `op_launch`/`own` machinery (detail.gleam:684-716, 1348-1366).
- Produces: `pub type DayEdit { DayEdit(working: Bool, starts: String, ends: String) }`, `pub type WeekForm { WeekForm(effective: String, days: List(DayEdit), error: Option(String)) }`, `pub fn build_week_command(engineer_id: Int, form: WeekForm) -> Result(gateway.Command, String)` (pure, tested), plus the panel Task 6 hangs focus-block launchers on.

- [ ] **Step 1: Add availability state + fetch.**

In `client/src/client/page/people/detail.gleam`:
- Add to `Model`: `availability: AvailabilityData` and `week_form: Option(WeekForm)`.
- Add:
```gleam
pub type AvailabilityData {
  AvailabilityLoading
  AvailabilityLoaded(record: AvailabilityRecord)
  AvailabilityFailed(message: String)
}
```
- Extend `Msg` with `AvailabilityFetched(as_of: Date, engineer_id: Int, result: Result(AvailabilityRecord, rsvp.Error(String)))`, `WeekOpened`, `WeekCancelled`, `WeekEffectiveEdited(String)`, `WeekDayToggled(Int)`, `WeekStartsEdited(Int, String)`, `WeekEndsEdited(Int, String)`, `WeekSubmitted`.
- In `fetch_detail`'s batch add:
```gleam
api.get(
  "/api/engineers/" <> int.to_string(engineer_id) <> "/availability?as_of=" <> time.iso_date(as_of),
  availability_view.availability_record_decoder(),
  fn(result) { AvailabilityFetched(as_of, engineer_id, result) },
)
```
with the same stale-guard the location fetch uses (ignore when `as_of`/`engineer_id` mismatch the model).

- [ ] **Step 2: Pure week-form model + builder (tests first, RED).**

Create `client/test/availability_form_test.gleam`:

```gleam
import client/page/people/detail
import gleam/option.{None, Some}
import gleam/time/calendar
import shared/availability/command as availability_command
import shared/command as gateway

fn default_days() -> List(detail.DayEdit) {
  [
    detail.DayEdit(True, "09:00", "17:00"),
    detail.DayEdit(True, "09:00", "17:00"),
    detail.DayEdit(True, "09:00", "17:00"),
    detail.DayEdit(True, "09:00", "17:00"),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
  ]
}

pub fn build_week_command_from_a_valid_form_test() {
  let form =
    detail.WeekForm(effective: "2026-07-06", days: default_days(), error: None)
  assert detail.build_week_command(1, form)
    == Ok(
      gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
        engineer_id: 1,
        effective: calendar.Date(2026, calendar.July, 6),
        days: [
          availability_command.DayHours(0, Some(#("09:00", "17:00"))),
          availability_command.DayHours(1, Some(#("09:00", "17:00"))),
          availability_command.DayHours(2, Some(#("09:00", "17:00"))),
          availability_command.DayHours(3, Some(#("09:00", "17:00"))),
          availability_command.DayHours(4, None),
          availability_command.DayHours(5, None),
          availability_command.DayHours(6, None),
        ],
      )),
    )
}

pub fn build_week_command_rejects_a_working_day_without_hours_test() {
  let days = [
    detail.DayEdit(True, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
    detail.DayEdit(False, "", ""),
  ]
  let form = detail.WeekForm(effective: "2026-07-06", days:, error: None)
  assert detail.build_week_command(1, form)
    == Error("Monday needs start and end times")
}

pub fn build_week_command_rejects_a_bad_date_test() {
  let form =
    detail.WeekForm(effective: "not-a-date", days: default_days(), error: None)
  assert detail.build_week_command(1, form)
    == Error("effective date must be YYYY-MM-DD")
}
```

Run: `cd client && gleam test 2>&1 | tee /tmp/av-cli-red.log` — expect FAIL (types/functions missing).

- [ ] **Step 3: Implement the form model + builder (GREEN).**

In `detail.gleam` add:

```gleam
pub type DayEdit {
  DayEdit(working: Bool, starts: String, ends: String)
}

pub type WeekForm {
  WeekForm(effective: String, days: List(DayEdit), error: Option(String))
}

const weekday_names = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
]

/// Build SetWorkSchedule from the weekly editor; the days list is always 7 long,
/// index = weekday (0 = Monday).
pub fn build_week_command(
  engineer_id: Int,
  form: WeekForm,
) -> Result(gateway.Command, String) {
  use effective <- result.try(
    wire.parse_iso_date(form.effective)
    |> result.replace_error("effective date must be YYYY-MM-DD"),
  )
  use days <- result.try(
    form.days
    |> list.index_map(fn(day, weekday) { day_hours(day, weekday) })
    |> result.all,
  )
  Ok(
    gateway.AvailabilityCommand(availability_command.SetWorkSchedule(
      engineer_id:,
      effective:,
      days:,
    )),
  )
}

fn day_hours(
  day: DayEdit,
  weekday: Int,
) -> Result(availability_command.DayHours, String) {
  let name = weekday_name(weekday)
  case day.working, string.trim(day.starts), string.trim(day.ends) {
    False, _, _ -> Ok(availability_command.DayHours(weekday, None))
    True, "", _ -> Error(name <> " needs start and end times")
    True, _, "" -> Error(name <> " needs start and end times")
    True, starts, ends ->
      Ok(availability_command.DayHours(weekday, Some(#(starts, ends))))
  }
}

fn weekday_name(weekday: Int) -> String {
  case list.drop(weekday_names, weekday) {
    [name, ..] -> name
    [] -> "Day"
  }
}
```

(Check `list.index_map`'s argument order in this stdlib version — element first or index first — and match it. Imports: `gleam/result`, `gleam/string`, `shared/wire`, `shared/availability/command as availability_command`, `shared/availability/view as availability_view`.)

Run: `cd client && gleam test 2>&1 | tee /tmp/av-cli-green.log` — expect PASS.

- [ ] **Step 4: Render the panel + editor modal; wire update.**

- Panel (slot it beside `location_panel` in the side column, detail.gleam:809): `ui.panel(title: "Availability", …)` showing, from `AvailabilityLoaded(record)`:
  - the 7-day grid: weekday name + `"09:00–17:00"` (both `Some`) or `"—"`;
  - the focus-block list: title + `local_time`-style rendering of `starts_at` with `offset_minutes` when `Some` (add a small private helper mirroring `meetings.local_time`'s `timestamp.parse_rfc3339` + offset shift) or the raw UTC time otherwise;
  - a "Holidays" strip: `holiday_on` (via `time.format_date` after `wire`-parsing) + name;
  - an "Edit hours" launcher gated like `op_launch(permissions, own, …)` — the weekly editor is bespoke, so gate directly: `ui.when_permitted(ui.permit(permissions, own:, kind: ui.OpAddFocusBlock), …)` reuses the `ManageAvailability`-keyed kind from Task 6; until Task 6 lands, gate with `set.contains(permissions, access.availability_manage_any) || own && set.contains(permissions, access.availability_manage_own)` and note it.
- `WeekOpened` seeds `WeekForm(effective: time.iso_date(as_of), days: from the loaded week (DaySlot Some→DayEdit(True, starts, ends), None→DayEdit(False, "", "")), error: None)`.
- `WeekDayToggled(index)` / `WeekStartsEdited(index, value)` / `WeekEndsEdited(index, value)` rewrite one list entry (`list.index_map` returning the edited row at the matching index).
- `WeekSubmitted` → `build_week_command(model.engineer_id, form)`; `Ok(command)` → `api.submit_operation(command, OperationReturned)`; `Error(message)` → set `form.error`. `OperationReturned(Ok(_))` closes the form and refetches (reuse the page's existing success path).
- Modal markup mirrors the page's existing `ui.modal(title: "Edit weekly hours", …, confirm_label: "Save hours")` with a checkbox + two `<input type="time">`-style text inputs per row (plain text inputs are fine — the builder validates).

Run: `cd client && gleam build 2>&1 | tee /tmp/av-cli5.log` — expect compile.

- [ ] **Step 5: Commit.**

```bash
git add client/src/client/page/people/detail.gleam client/test/availability_form_test.gleam
git commit -m "Show and edit weekly availability on the People detail page

An Availability panel renders the as-of weekly grid, focus blocks in the engineer's local time, and upcoming regional holidays; a bespoke 7-row editor builds the SetWorkSchedule batch command, gated by availability.manage own/any."
```

---

### Task 6: Focus-block ops via the op-form engine

**Files:**
- Modify: `client/src/client/ui.gleam`
- Modify: `client/src/client/page/people/detail.gleam`
- Test: `client/test/availability_form_test.gleam`

**Interfaces:**
- Consumes: `shared/availability/command.{AddFocusBlock, RemoveFocusBlock}`; existing `OpField`s `FEngineerId`, `FEffective`, `FStartsAt`, `FDurationMinutes`, `FTimezone`, `FTitle`.
- Produces: `OpKind`s `OpAddFocusBlock`, `OpRemoveFocusBlock` (both keyed `policy.ManageAvailability`); new `OpField` `FFocusBlockId` + `OpForm.focus_block_id`.

- [ ] **Step 1: Extend `ui.gleam`.**

- `OpKind`: add `OpAddFocusBlock`, `OpRemoveFocusBlock`.
- `op_command_key`: both → `policy.ManageAvailability`.
- `OpField`: add `FFocusBlockId`. `OpForm`: add `focus_block_id: String`. `blank_op_form`: `focus_block_id: ""`. `update_op_form`: `FFocusBlockId -> OpForm(..form, focus_block_id: value)`.
- `build_command` arms (before the final error arm, using the meeting arms at ui.gleam:1150-1197 as the template):

```gleam
    OpAddFocusBlock -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use date <- result.try(require_date(form.effective, "date"))
      use starts_at <- result.try(require_text(form.starts_at, "start time"))
      use duration_minutes <- result.try(require_int(
        form.duration_minutes,
        "duration",
      ))
      use timezone <- result.try(require_text(form.timezone, "timezone"))
      use title <- result.try(require_text(form.title, "title"))
      Ok(
        gateway.AvailabilityCommand(availability_command.AddFocusBlock(
          engineer_id:,
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          title:,
        )),
      )
    }
    OpRemoveFocusBlock -> {
      use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
      use focus_block_id <- result.try(require_int(
        form.focus_block_id,
        "focus block id",
      ))
      Ok(
        gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
          engineer_id:,
          focus_block_id:,
        )),
      )
    }
```

Add `import shared/availability/command as availability_command`.

- [ ] **Step 2: Clean-build the client.**

Run: `cd client && gleam clean && gleam build 2>&1 | tee /tmp/av-cli6.log`
Expected: compiles once every `case OpKind` site handles the two new kinds (the build names each inexhaustive site — add arms following the meeting kinds).

- [ ] **Step 3: Wire the panel launchers + modals.**

In `page/people/detail.gleam`'s Availability panel:
- "Add focus block" launcher: `op_launch(permissions, own, ui.OpAddFocusBlock, "Add focus block", True)`; on open, prefill `FEngineerId` with the page's engineer id (and `FTimezone` with the engineer's current location timezone when loaded — mirror `prefill_location`).
- Per-block "Remove" launcher prefilling `FEngineerId` + `FFocusBlockId`.
- Add the two kinds to the page's `op_fields(kind, form)`: `OpAddFocusBlock` → `[FEffective (label "Date"), FStartsAt ("Start (HH:MM)"), FDurationMinutes ("Duration (minutes)"), FTimezone, FTitle]`; `OpRemoveFocusBlock` → `[]` (confirm-only; the prefilled ids render in the modal title). Modal titles "Add focus block" / "Remove focus block", confirm labels "Add" / "Remove".
- Replace Task 5's interim permission check on "Edit hours" with `op_launch`-consistent gating now that a `ManageAvailability`-keyed kind exists (a `ui.when_permitted(ui.permit(permissions, own:, kind: ui.OpAddFocusBlock), …)` wrapper around the bespoke launcher).

- [ ] **Step 4: Builder tests (RED then GREEN).**

Add to `client/test/availability_form_test.gleam`:

```gleam
pub fn build_add_focus_block_command_test() {
  let form =
    ui.blank_op_form(ui.OpAddFocusBlock, calendar.Date(2026, calendar.July, 6))
    |> ui.update_op_form(ui.FEngineerId, "2")
    |> ui.update_op_form(ui.FEffective, "2026-07-08")
    |> ui.update_op_form(ui.FStartsAt, "13:00")
    |> ui.update_op_form(ui.FDurationMinutes, "90")
    |> ui.update_op_form(ui.FTimezone, "America/Los_Angeles")
    |> ui.update_op_form(ui.FTitle, "Design deep-dive")
  assert ui.build_command(ui.OpAddFocusBlock, form)
    == Ok(
      gateway.AvailabilityCommand(availability_command.AddFocusBlock(
        engineer_id: 2,
        date: calendar.Date(2026, calendar.July, 8),
        starts_at: "13:00",
        duration_minutes: 90,
        timezone: "America/Los_Angeles",
        title: "Design deep-dive",
      )),
    )
}

pub fn build_remove_focus_block_command_test() {
  let form =
    ui.blank_op_form(ui.OpRemoveFocusBlock, calendar.Date(2026, calendar.July, 6))
    |> ui.update_op_form(ui.FEngineerId, "2")
    |> ui.update_op_form(ui.FFocusBlockId, "7")
  assert ui.build_command(ui.OpRemoveFocusBlock, form)
    == Ok(
      gateway.AvailabilityCommand(availability_command.RemoveFocusBlock(
        engineer_id: 2,
        focus_block_id: 7,
      )),
    )
}
```

Run: `cd client && gleam test 2>&1 | tee /tmp/av-cli6b.log` — expect PASS.

- [ ] **Step 5: Commit.**

```bash
git add client/src/client/ui.gleam client/src/client/page/people/detail.gleam client/test/availability_form_test.gleam
git commit -m "Add and remove focus blocks from the Availability panel via the op-form engine

Two ManageAvailability-keyed OpKinds build the flat focus-block commands; launchers prefill the engineer and block ids and respect own/any scoping."
```

---

### Task 7: Locations holidays section + import modal

**Files:**
- Modify: `client/src/client/page/locations.gleam`
- Test: `client/test/availability_form_test.gleam`

**Interfaces:**
- Consumes: `shared/availability/view.{HolidayListing, holiday_listing_decoder}`; `shared/availability/command.{ImportHolidays, HolidayRow}`; `access.holiday_manage`.
- Produces: `pub fn parse_holiday_lines(text: String) -> Result(List(availability_command.HolidayRow), String)` (pure, tested).

- [ ] **Step 1: Parser tests first (RED).**

Add to `client/test/availability_form_test.gleam`:

```gleam
import client/page/locations

pub fn parse_holiday_lines_accepts_valid_lines_test() {
  let text = "AU,AU-NSW,2026-10-05,Labour Day\nGB,,2026-08-31,Summer Bank Holiday\n"
  assert locations.parse_holiday_lines(text)
    == Ok([
      availability_command.HolidayRow("AU", "AU-NSW", calendar.Date(2026, calendar.October, 5), "Labour Day"),
      availability_command.HolidayRow("GB", "", calendar.Date(2026, calendar.August, 31), "Summer Bank Holiday"),
    ])
}

pub fn parse_holiday_lines_rejects_a_malformed_line_test() {
  assert locations.parse_holiday_lines("AU,AU-NSW,not-a-date,Labour Day")
    == Error("line 1: date must be YYYY-MM-DD")
}

pub fn parse_holiday_lines_rejects_empty_input_test() {
  assert locations.parse_holiday_lines("\n\n") == Error("no holiday lines found")
}
```

Run: `cd client && gleam test 2>&1 | tee /tmp/av-cli7-red.log` — expect FAIL.

- [ ] **Step 2: Implement the parser (GREEN).**

In `locations.gleam`:

```gleam
/// Parse "country,region,date,name" lines (region empty = nationwide); commas beyond
/// the third stay in the name.
pub fn parse_holiday_lines(
  text: String,
) -> Result(List(availability_command.HolidayRow), String) {
  let lines =
    text
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
  case lines {
    [] -> Error("no holiday lines found")
    _ ->
      lines
      |> list.index_map(fn(line, index) { parse_line(line, index + 1) })
      |> result.all
  }
}

fn parse_line(
  line: String,
  number: Int,
) -> Result(availability_command.HolidayRow, String) {
  let prefix = "line " <> int.to_string(number) <> ": "
  case string.split(line, ",") {
    [country, region, date_text, ..name_parts] -> {
      let name = string.trim(string.join(name_parts, ","))
      case wire.parse_iso_date(string.trim(date_text)) {
        Error(_) -> Error(prefix <> "date must be YYYY-MM-DD")
        Ok(holiday_on) ->
          case string.trim(country), name {
            "", _ -> Error(prefix <> "country is required")
            _, "" -> Error(prefix <> "name is required")
            trimmed_country, _ ->
              Ok(availability_command.HolidayRow(
                country: trimmed_country,
                region: string.trim(region),
                holiday_on:,
                name:,
              ))
          }
      }
    }
    _ -> Error(prefix <> "expected country,region,date,name")
  }
}
```

(Same `list.index_map` argument-order check as Task 5. `[country, region, date_text, ..name_parts]` with empty `name_parts` means a 3-field line: `string.join([], ",")` is `""` → "name is required", which covers the short-line case.)

Run: `cd client && gleam test 2>&1 | tee /tmp/av-cli7-green.log` — expect PASS.

- [ ] **Step 3: Holidays section + import modal.**

In `locations.gleam`:
- Add to `Model`: `holidays: HolidaysState` and `import_form: Option(ImportForm)`; `pub type HolidaysState { HolidaysLoading HolidaysLoaded(entries: List(HolidayListing)) HolidaysFailed(detail: String) }`, `pub type ImportForm { ImportForm(text: String, error: Option(String)) }`.
- `init`/`refetch`: `effect.batch([fetch(as_of), fetch_holidays(as_of)])` where `fetch_holidays` is `api.get("/api/holidays?as_of=" <> time.iso_date(as_of), decode.list(availability_view.holiday_listing_decoder()), fn(result) { HolidaysFetched(as_of, result) })` with the same stale-guard as `Fetched`.
- `Msg`: add `HolidaysFetched(as_of: Date, result: …)`, `ImportOpened`, `ImportCancelled`, `ImportTextEdited(String)`, `ImportSubmitted`.
- `view`: below the locations table render a "Public holidays" section listing `region_name`, formatted `holiday_on`, `name` (date order arrives from the server). Header action "Import holidays" shown when `set.contains(permissions, access.holiday_manage)` (check the page's `view` signature for how permissions arrive — mirror how the Set-location launcher receives them).
- `ImportSubmitted` → `parse_holiday_lines(form.text)`; `Ok(rows)` → `api.submit_operation(gateway.AvailabilityCommand(availability_command.ImportHolidays(rows:)), OperationReturned)`; `Error(message)` → set `form.error`. Success closes the modal and refetches holidays. The modal is a `ui.modal(title: "Import holidays", …, confirm_label: "Import")` wrapping a textarea bound to `ImportTextEdited` plus a hint line `"country,region,date,name — one holiday per line; leave region empty for nationwide"`.

Run: `cd client && gleam build 2>&1 | tee /tmp/av-cli7b.log` — expect compile.

- [ ] **Step 4: Commit.**

```bash
git add client/src/client/page/locations.gleam client/test/availability_form_test.gleam
git commit -m "List public holidays on the Locations page with a paste-to-import modal

A holidays section shows upcoming dates by region; holiday.manage holders paste country,region,date,name lines that parse client-side into one ImportHolidays batch."
```

---

### Task 8: End-to-end flow

**Files:**
- Create: `e2e/availability.spec.js`

**Interfaces:**
- Consumes: the Task 4 seed (default hours, Priya's dropped Friday, Marcus's focus block, 5 holidays) and permission grants; the running bundle (`bin/e2e` rebuilds it first).

- [ ] **Step 1: Write the Playwright spec.**

Create `e2e/availability.spec.js` mirroring `e2e/meetings.spec.js`'s helpers (`signInAs`, `navigateTo`, as-of control; check `e2e/helpers.js` for the available sign-ins — `rbac_seed.sql` maps priya/marcus/aisha → engineer, ops → manager, admin → owner; if `signInAs` only knows role labels, extend the spec with the same `sign_in` POST the RBAC spec uses for named users). Cover, asserting user-visible content only:
- As Admin at as-of 2026-07-05, open Priya's People detail: the Availability panel shows Monday 09:00–17:00 and Friday "—"; the holidays strip lists "Summer Bank Holiday".
- Open Marcus's detail at as-of 2026-06-16: the focus block "Deep work: incident review" is listed.
- As Admin, edit Marcus's weekly hours (drop Wednesday, effective 2026-07-06); the grid shows Wednesday "—" after save.
- Add a focus block to Marcus ("Architecture review", a date after the as-of), it appears; remove it, it disappears.
- On the Locations page the Public holidays section lists "Labour Day" under "New South Wales"; as Admin the Import button is visible.
- Sign in as an engineer (Priya): her own detail shows "Edit hours"; Marcus's detail hides it. If `helpers.js` cannot sign in as a named engineer, replace this scenario: sign in as Ops (manager — holds `.any`, lacks `holiday.manage`) and assert the Locations Import button is absent while "Edit hours" is present on both details.
- Pick an as-of date already in `helpers.js`'s `DAY_INDEX` (2026-07-05 exists since Phase C); add any new date the spec scrubs to.

- [ ] **Step 2: Run it.**

Run: `TEMPO_DB_PORT=5435 bin/e2e availability 2>&1 | tee /tmp/av-e2e.log`
Expected: PASS. The e2e DB may predate the availability seed — if rows are missing, `docker exec tempo-db psql -U tempo -c 'DROP DATABASE tempo_e2e WITH (FORCE)'` and re-run (bin/e2e recreates + reseeds).

Then the full suite: `TEMPO_DB_PORT=5435 bin/e2e 2>&1 | tee /tmp/av-e2e-full.log` — expect all green.

- [ ] **Step 3: Commit.**

```bash
git add e2e/availability.spec.js e2e/helpers.js
git commit -m "e2e: weekly hours, focus blocks, and holidays across the availability surfaces"
```

---

## Final gate (after Task 8)

```bash
cd /Users/michaelbuhot/src/mbuhot/tempo/server && gleam clean && gleam build 2>&1 | tee /tmp/av-final-srv.log
cd /Users/michaelbuhot/src/mbuhot/tempo/shared && gleam build 2>&1 | tee /tmp/av-final-shr.log
cd /Users/michaelbuhot/src/mbuhot/tempo/client && gleam clean && gleam build 2>&1 | tee /tmp/av-final-cli.log
cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/test 2>&1 | tee /tmp/av-final-test.log
cd /Users/michaelbuhot/src/mbuhot/tempo && TEMPO_DB_PORT=5435 bin/e2e 2>&1 | tee /tmp/av-final-e2e.log
```
Expected: all green. Then update issue #43/#42 status (show text for approval before posting) and the `scheduling-system` memory.

---

## Self-Review notes

- **Spec coverage:** B1 (UI for all three) → Tasks 5/6/7; B2 ('' sentinel) → Task 1 schema + Task 3 codecs (region always a string); B3 (seed defaults) → Task 4 seed; B4 (seed + import command, unknown region rejected) → Tasks 3/4/7; B5 (Owned + holiday.manage) → Task 3 policy + Task 4 grants + Task 8 RBAC scenario; B6 (whole-week batch + bespoke grid, flat focus ops) → Tasks 3/5/6; B7 (temporal work_schedule, plain focus_block) → Tasks 1/2; B8 (region normalize + FK) → Task 1. Reads spec table → Task 4. Testing matrix → Tasks 2–8 (dispatch splits/validation, read folds, client builders/parser, e2e scenarios).
- **Known drift risks flagged inline:** generated Squirrel signatures (Task 1 Step 6 inspection gates Tasks 2/4), `policy.target` exact return idiom (Task 3 Step 3), `list.index_map` argument order (Tasks 5/7), e2e named-engineer sign-in (Task 8 fallback given).
- **Ownership enforcement is two-layer by design:** `policy.target` trusts the command's `engineer_id` (client-supplied), and the focus-block DELETE pair-matches `(id, engineer_id)` so a spoofed owner deletes nothing (`NoSuchVersion`). `SetWorkSchedule`/`AddFocusBlock` writes with a spoofed `engineer_id` are blocked at authorize time because `own` computes false for a mismatched principal.
- **Deferred to Phase D:** the finder, free/busy computation, meeting suggestions (spec "Out of scope").
