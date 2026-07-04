# Scheduling Phase A — Engineer Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `engineer_location` — a dated fact carrying an engineer's country/region and IANA TZID — end to end from PostgreSQL through Squirrel, `shared`, the server, and a Lustre Locations screen, so an engineer's timezone becomes an as-of query.

**Architecture:** Follows tempo's per-concept vertical slice. A new temporal fact table with a `WITHOUT OVERLAPS` primary key; typed SQL via Squirrel; a `shared` read type + JSON codec and a write command threaded through the universal `dispatch → route → record_facts(event_log, audit_id)` seam; a new `location` server concept (`command`/`view`/`http`/`sql`); and a `Locations` client page anchored to the global as-of slider. All timezone handling stays in PostgreSQL — Gleam never computes timezones.

**Tech Stack:** Gleam 1.17 (Erlang + JS targets), PostgreSQL 19beta1, Squirrel (typed SQL), Wisp, pog, Lustre, gleeunit, Playwright.

**UI reference:** `docs/prototypes/2026-07-04-scheduling.html` — the Locations listing and Set-location modal there are the visual target for Tasks 9–10 (token-only mockup; final styling lifts real tokens from `client/styles/`).

## Global Constraints

- **DB port is 5435 this environment** (the 5434 Docker proxy is wedged). `bin/migrate`/`bin/test`/`bin/serve` read `TEMPO_DB_PORT` (default 5434) — export `TEMPO_DB_PORT=5435`. `bin/squirrel` hardcodes the URL — run it with `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo`.
- **Migrate before Squirrel.** `bin/squirrel` introspects the live DB, so apply the migration (`bin/migrate`) before regenerating.
- **Clean-build after adding a union variant.** Incremental Gleam builds can mask an inexhaustive `case`; run `gleam clean && gleam build` in the affected package after extending `Command`, `Fact`, `CommandKey`, `OpKind`, or `Route`.
- **Exhaustive-enum wiring is compiler-forced.** Extending `Command` (shared) obliges arms in `encode_command`, `grouped_command_decoder`, `policy.key`, `policy.requirement` (via a new `CommandKey`), `auth.command_tag`, and `command.dispatch_in`'s `route`. Extending `Fact` obliges a `repository.write` arm. The build will name each omission.
- **TDD, red then green.** Stub with `todo`, write one failing test, confirm it fails on assertion/`todo` (not a compile error), implement minimally, confirm green, commit. Never pipe test output through `head`/`grep` in the same command — redirect to a file.
- **Assertions:** `assert expr == expected`, exact deterministic values (base seed "now" is 2026-06-15). No conditional assertions. No inline comments; doc comments only, terse.
- **Gleam server tests** run against DB `tempo_test` via `bin/test`; they use the base seed only. **e2e** runs against `tempo_e2e` via `bin/e2e` (base + financials seed) and rebuilds the client bundle.
- **Commit** after each green task; list files explicitly (no `git add -A`).

## File Structure

**New files:**
- `server/priv/migrations/20260704140000_engineer_location.sql` — the table.
- `server/src/tempo/server/location/sql/{engineer_location_upsert,engineer_locations,engineer_location_history,timezone_valid}.sql` — queries.
- `server/src/tempo/server/location/sql.gleam` — Squirrel-generated (do not hand-edit).
- `server/src/tempo/server/location/command.gleam` — the write handler (`route` + TZID guard).
- `server/src/tempo/server/location/view.gleam` — reads (listing + history) → shared types.
- `server/src/tempo/server/location/http.gleam` — Wisp handlers for the two GET endpoints.
- `shared/src/shared/location/view.gleam` — `LocationRecord`, `EngineerLocation` + codecs.
- `shared/src/shared/location/command.gleam` — `LocationCommand` + codec.
- `client/src/client/page/locations.gleam` — the Locations page (MVU).
- `client/styles/locations.scss` — table styling.

**Modified files:** `shared/src/shared/command.gleam`, `shared/src/shared/access.gleam`, `shared/src/shared/access/policy.gleam`, `server/src/tempo/server/fact.gleam`, `server/src/tempo/server/repository.gleam`, `server/src/tempo/server/command.gleam`, `server/src/tempo/server/auth.gleam`, `server/src/tempo/server/web/router.gleam`, `server/priv/seed/base_seed.sql`, `server/priv/seed/rbac_seed.sql`, `client/src/client/route.gleam`, `client/src/client/app.gleam`, `client/styles/main.scss`, and the sidebar nav in `app.gleam`.

---

### Task 1: Migration — `engineer_location` table

**Files:**
- Create: `server/priv/migrations/20260704140000_engineer_location.sql`

**Interfaces:**
- Produces: table `engineer_location(engineer_id, located_during, country, region, timezone, audit_id)` with temporal PK; `located_during @> date` is the as-of lookup.

- [ ] **Step 1: Write the migration**

```sql
-- 20260704140000_engineer_location.sql — an engineer's location over time (Phase A of
-- scheduling). `located_during` is the application-time period; the timezone is an IANA
-- TZID (Australia/Sydney), so an engineer's zone on any date is `located_during @> date`.
-- country/region are ISO codes carried as plain text in Phase A; Phase B adds the
-- holiday_region FK. Standalone like engineer_contact (no PERIOD containment).
CREATE TABLE engineer_location (
  engineer_id    bigint    NOT NULL REFERENCES engineer (id),
  located_during daterange NOT NULL,
  country        text      NOT NULL,
  region         text,
  timezone       text      NOT NULL,
  audit_id       bigint    REFERENCES event_log (id),
  CONSTRAINT engineer_location_no_overlap
    PRIMARY KEY (engineer_id, located_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX engineer_location_audit_id_idx ON engineer_location (audit_id);
```

- [ ] **Step 2: Apply it**

Run: `TEMPO_DB_PORT=5435 bin/migrate`
Expected: output lists `20260704140000_engineer_location` applied; re-running is a no-op.

- [ ] **Step 3: Verify the table shape**

Run: `docker compose exec -T db psql -U tempo -d tempo -c "\d engineer_location" > /tmp/loc-schema.txt 2>&1; cat /tmp/loc-schema.txt`
Expected: columns `engineer_id, located_during, country, region, timezone, audit_id`; a GiST PK `engineer_location_no_overlap`.

- [ ] **Step 4: Commit**

```bash
git add server/priv/migrations/20260704140000_engineer_location.sql
git commit -m "Add engineer_location temporal fact table"
```

---

### Task 2: Seed data + grant `location.manage`

Seeds locations for the existing cast (including a mid-range relocation so as-of reads are testable) and grants the new permission so the write path is reachable in dev/e2e. The permission constant itself is added in Task 6; this task only touches seed SQL, so run it after Task 6 if the constant is referenced — here it is referenced only by string in `rbac_seed.sql`, so ordering is free.

**Files:**
- Modify: `server/priv/seed/base_seed.sql` (append location facts)
- Modify: `server/priv/seed/rbac_seed.sql` (grant `location.manage` to manager + owner)

**Interfaces:**
- Consumes: existing seed engineer ids and the seed's event_log/audit pattern.
- Produces: seeded `engineer_location` rows; `location.manage` on manager/owner roles.

- [ ] **Step 1: Read the existing seed pattern**

Read how `base_seed.sql` seeds a temporal fact with an audit id (search for `engineer_contact` inserts and the seed's `event_log`/`audit` handling) and how `rbac_seed.sql` maps roles to permissions. Mirror those exactly.

- [ ] **Step 2: Append location facts to `base_seed.sql`**

Seed at least: Marcus Chen in `America/Los_Angeles` (US) open-ended; Priya Sharma with two spans — `Australia/Sydney` (AU) `[2024-03-01, 2026-07-01)` then `Europe/London` (GB) `[2026-07-01, )` (the relocation); Aisha Okafor in `Europe/London` (GB). Use the existing seed engineer ids and the seed's audit-id mechanism. Example shape (adapt column/audit handling to the file's convention):

```sql
INSERT INTO engineer_location (engineer_id, located_during, country, region, timezone, audit_id)
VALUES
  (<marcus_id>, daterange('2024-03-01', NULL, '[)'), 'US', 'US-CA', 'America/Los_Angeles', <seed_audit_id>),
  (<priya_id>,  daterange('2024-03-01','2026-07-01','[)'), 'AU', 'AU-NSW', 'Australia/Sydney', <seed_audit_id>),
  (<priya_id>,  daterange('2026-07-01', NULL, '[)'), 'GB', 'GB-LND', 'Europe/London', <seed_audit_id>),
  (<aisha_id>,  daterange('2023-09-12', NULL, '[)'), 'GB', 'GB-LND', 'Europe/London', <seed_audit_id>);
```

- [ ] **Step 3: Grant the permission in `rbac_seed.sql`**

Add `location.manage` to the same role rows that already receive management permissions such as `allocation.manage` (manager and owner). Follow the file's existing insert shape.

- [ ] **Step 4: Reseed and verify**

Run: `TEMPO_DB_PORT=5435 bin/reseed` then
`docker compose exec -T db psql -U tempo -d tempo -c "SELECT engineer_id, lower(located_during), upper(located_during), timezone FROM engineer_location ORDER BY engineer_id, lower(located_during)" > /tmp/loc-seed.txt 2>&1; cat /tmp/loc-seed.txt`
Expected: Priya has two rows, the earlier ending 2026-07-01, the later open-ended `Europe/London`.

- [ ] **Step 5: Commit**

```bash
git add server/priv/seed/base_seed.sql server/priv/seed/rbac_seed.sql
git commit -m "Seed engineer locations (incl. a relocation) and grant location.manage"
```

---

### Task 3: SQL queries + Squirrel regeneration

**Files:**
- Create: `server/src/tempo/server/location/sql/engineer_location_upsert.sql`
- Create: `server/src/tempo/server/location/sql/engineer_locations.sql`
- Create: `server/src/tempo/server/location/sql/engineer_location_history.sql`
- Create: `server/src/tempo/server/location/sql/timezone_valid.sql`
- Create (generated): `server/src/tempo/server/location/sql.gleam`

**Interfaces:**
- Produces (generated fns): `engineer_location_upsert(db, engineer_id: Int, effective: Date, country: String, region: Option(String), timezone: String, audit_id: Int)`; `engineer_locations(db, as_of: Date) -> EngineerLocationsRow`; `engineer_location_history(db, engineer_id: Int) -> EngineerLocationHistoryRow`; `timezone_valid(db, timezone: String) -> TimezoneValidRow(valid: Bool)`. Exact generated names/param order come from Squirrel — read `sql.gleam` after Step 5 and use them verbatim downstream.

- [ ] **Step 1: Write `engineer_location_upsert.sql`** (delete-then-insert, the `engineer_contact_upsert` idiom)

```sql
-- engineer_location_upsert.sql — set an engineer's location from $2 onward. The temporal
-- DELETE clips the row covering $2 to [start, $2) and removes rows starting at/after $2,
-- then inserts [$2, NULL) with the new values, superseding scheduled future versions.
-- $1 engineer_id, $2 effective, $3 country, $4 region (nullable), $5 timezone, $6 audit_id.
WITH deleted AS (
  DELETE FROM engineer_location
     FOR PORTION OF located_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_location
  (engineer_id, located_during, country, region, timezone, audit_id)
VALUES ($1, daterange($2::date, NULL, '[)'), $3, $4, $5, $6);
```

- [ ] **Step 2: Write `engineer_locations.sql`** (as-of listing, LEFT JOIN so location-less engineers still appear)

```sql
-- engineer_locations.sql — every engineer and their location as-of $1, or NULLs when none
-- is set on that date. $1 = as-of date.
SELECT
  engineer_current.id   AS engineer_id,
  engineer_current.name AS name,
  loc.country           AS country,
  loc.region            AS region,
  loc.timezone          AS timezone,
  lower(loc.located_during) AS valid_from,
  upper(loc.located_during) AS valid_to
FROM engineer_current
LEFT JOIN engineer_location loc
  ON loc.engineer_id = engineer_current.id
 AND loc.located_during @> $1::date
ORDER BY engineer_current.name;
```

- [ ] **Step 3: Write `engineer_location_history.sql`**

```sql
-- engineer_location_history.sql — all location spans for one engineer, oldest first.
-- $1 = engineer_id.
SELECT
  engineer_location.country  AS country,
  engineer_location.region   AS region,
  engineer_location.timezone AS timezone,
  lower(engineer_location.located_during) AS valid_from,
  upper(engineer_location.located_during) AS valid_to
FROM engineer_location
WHERE engineer_location.engineer_id = $1
ORDER BY lower(engineer_location.located_during);
```

- [ ] **Step 4: Write `timezone_valid.sql`**

```sql
-- timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1) AS valid;
```

- [ ] **Step 5: Regenerate Squirrel and build**

Run: `cd server && DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo gleam run -m squirrel && cd .. && (cd server && gleam build) > /tmp/sq.txt 2>&1; tail -20 /tmp/sq.txt`
Expected: `server/src/tempo/server/location/sql.gleam` created with the four fns; server compiles. Read the generated file and note the exact fn names, param order, and row-type field names for later tasks.

- [ ] **Step 6: Commit**

```bash
git add server/src/tempo/server/location/sql/ server/src/tempo/server/location/sql.gleam
git commit -m "Add engineer_location queries (upsert, as-of listing, history, tz validation)"
```

---

### Task 4: `shared` read type `LocationRecord` + `EngineerLocation` + codecs

**Files:**
- Create: `shared/src/shared/location/view.gleam`
- Test: `server/test/codec_test.gleam` (add cases)

**Interfaces:**
- Produces: `LocationRecord(country: String, region: Option(String), timezone: String, valid_from: Date, valid_to: Option(Date))` with `encode_location_record` / `location_record_decoder`; `EngineerLocation(engineer_id: Int, name: String, location: Option(LocationRecord))` with `encode_engineer_location` / `engineer_location_decoder`.

- [ ] **Step 1: Write a failing round-trip test** in `server/test/codec_test.gleam`

```gleam
pub fn engineer_location_round_trips_test() {
  let original =
    location_view.EngineerLocation(
      engineer_id: 7,
      name: "Priya Sharma",
      location: Some(location_view.LocationRecord(
        country: "GB",
        region: Some("GB-LND"),
        timezone: "Europe/London",
        valid_from: Date(2026, July, 1),
        valid_to: None,
      )),
    )
  assert round_trip(
      original,
      location_view.encode_engineer_location,
      location_view.engineer_location_decoder(),
    )
    == original
}
```

Add the import `import shared/location/view as location_view` and ensure `Some`/`None` (`gleam/option`) and `July` (`gleam/time/calendar`) are in scope (mirror the file's existing imports).

- [ ] **Step 2: Run — confirm it fails to compile-then-fails on the missing module**

Run: `cd server && gleam test > /tmp/t.txt 2>&1; tail -30 /tmp/t.txt`
Expected: unknown module `shared/location/view` (the module doesn't exist yet).

- [ ] **Step 3: Write `shared/src/shared/location/view.gleam`**

```gleam
//// The read model for an engineer's location: a `LocationRecord` (a single dated span)
//// and `EngineerLocation` (an engineer plus their location as-of a date, or none).

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{type Date}
import shared/wire

pub type LocationRecord {
  LocationRecord(
    country: String,
    region: Option(String),
    timezone: String,
    valid_from: Date,
    valid_to: Option(Date),
  )
}

pub type EngineerLocation {
  EngineerLocation(engineer_id: Int, name: String, location: Option(LocationRecord))
}

pub fn encode_location_record(record: LocationRecord) -> Json {
  let LocationRecord(country:, region:, timezone:, valid_from:, valid_to:) = record
  json.object([
    #("country", json.string(country)),
    #("region", json.nullable(region, json.string)),
    #("timezone", json.string(timezone)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_option_date(valid_to)),
  ])
}

pub fn location_record_decoder() -> Decoder(LocationRecord) {
  use country <- decode.field("country", decode.string)
  use region <- decode.field("region", decode.optional(decode.string))
  use timezone <- decode.field("timezone", decode.string)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.option_date_decoder())
  decode.success(LocationRecord(country:, region:, timezone:, valid_from:, valid_to:))
}

pub fn encode_engineer_location(entry: EngineerLocation) -> Json {
  let EngineerLocation(engineer_id:, name:, location:) = entry
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("location", json.nullable(location, encode_location_record)),
  ])
}

pub fn engineer_location_decoder() -> Decoder(EngineerLocation) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use location <- decode.field("location", decode.optional(location_record_decoder()))
  decode.success(EngineerLocation(engineer_id:, name:, location:))
}
```

Confirm `wire.encode_option_date` / `wire.option_date_decoder` exist (the explorer confirmed they do); if a name differs, read `shared/src/shared/wire.gleam` and use the actual one.

- [ ] **Step 4: Run — confirm green**

Run: `cd server && gleam test > /tmp/t.txt 2>&1; tail -20 /tmp/t.txt`
Expected: the new test passes; format check clean (`gleam format`).

- [ ] **Step 5: Commit**

```bash
git add shared/src/shared/location/view.gleam server/test/codec_test.gleam
git commit -m "Add shared LocationRecord/EngineerLocation read types + codecs"
```

---

### Task 5: `shared` write command `LocationCommand` + Command-union wiring

**Files:**
- Create: `shared/src/shared/location/command.gleam`
- Modify: `shared/src/shared/command.gleam` (union variant, `encode_command`, `grouped_command_decoder`)
- Test: `server/test/codec_test.gleam`

**Interfaces:**
- Produces: `LocationCommand` with `SetEngineerLocation(engineer_id: Int, country: String, region: Option(String), timezone: String, effective: Date)`, `encode`, `decoder(op)`; `command.LocationCommand(LocationCommand)` variant.

- [ ] **Step 1: Write a failing round-trip test**

```gleam
pub fn command_set_location_round_trips_test() {
  let original =
    gateway.LocationCommand(location_command.SetEngineerLocation(
      engineer_id: 7,
      country: "GB",
      region: Some("GB-LND"),
      timezone: "Europe/London",
      effective: Date(2026, July, 1),
    ))
  assert round_trip(original, gateway.encode_command, gateway.command_decoder())
    == original
}
```

Add `import shared/location/command as location_command` (`gateway` is the existing alias for `shared/command`).

- [ ] **Step 2: Run — confirm failure** (`cd server && gleam test > /tmp/t.txt 2>&1; tail -30 /tmp/t.txt`) — unknown module / unknown variant.

- [ ] **Step 3: Write `shared/src/shared/location/command.gleam`** (mirror `shared/src/shared/leave/command.gleam`)

```gleam
//// The write command for engineer location: `SetEngineerLocation` sets a location from an
//// effective date onward. Tagged by `op` on the wire, like every aggregate command.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type LocationCommand {
  SetEngineerLocation(
    engineer_id: Int,
    country: String,
    region: Option(String),
    timezone: String,
    effective: Date,
  )
}

pub fn encode(command: LocationCommand) -> Json {
  case command {
    SetEngineerLocation(engineer_id:, country:, region:, timezone:, effective:) ->
      json.object([
        #("op", json.string("set_engineer_location")),
        #("engineer_id", json.int(engineer_id)),
        #("country", json.string(country)),
        #("region", json.nullable(region, json.string)),
        #("timezone", json.string(timezone)),
        #("effective", encode_date(effective)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(LocationCommand), Nil) {
  case op {
    "set_engineer_location" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use country <- decode.field("country", decode.string)
        use region <- decode.field("region", decode.optional(decode.string))
        use timezone <- decode.field("timezone", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(SetEngineerLocation(engineer_id:, country:, region:, timezone:, effective:))
      })
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 4: Wire into `shared/src/shared/command.gleam`** — add the import `import shared/location/command as location_command`, the union variant `LocationCommand(location_command.LocationCommand)`, the `encode_command` arm `LocationCommand(command) -> location_command.encode(command)`, and the decoder line `use <- try_group(location_command.decoder(op), LocationCommand)`.

- [ ] **Step 5: Clean-build (new union variant) + run**

Run: `cd shared && gleam clean && gleam build > /tmp/s.txt 2>&1; tail -20 /tmp/s.txt` then `cd ../server && gleam test > /tmp/t.txt 2>&1; tail -20 /tmp/t.txt`
Expected: shared builds (both targets); the new test passes.

- [ ] **Step 6: Commit**

```bash
git add shared/src/shared/location/command.gleam shared/src/shared/command.gleam server/test/codec_test.gleam
git commit -m "Add shared SetEngineerLocation command + wire into the Command union"
```

---

### Task 6: `shared` access + policy wiring

**Files:**
- Modify: `shared/src/shared/access.gleam` (const + `all()`)
- Modify: `shared/src/shared/access/policy.gleam` (`CommandKey`, `requirement`, `key`)

**Interfaces:**
- Produces: `access.location_manage = "location.manage"`; `policy.ManageLocation`.

- [ ] **Step 1: Add the permission constant** in `access.gleam`:

```gleam
/// Set any engineer's location (country/region/timezone over time).
pub const location_manage = "location.manage"
```

Add `location_manage` to the `all()` list.

- [ ] **Step 2: Extend the policy** in `access/policy.gleam` — add `LocationCommand` to the `shared/command` import list, add a `CommandKey` variant `ManageLocation`, a `requirement` arm `ManageLocation -> Direct(access.location_manage)`, and a `key` arm `LocationCommand(_) -> ManageLocation`.

- [ ] **Step 3: Clean-build shared**

Run: `cd shared && gleam clean && gleam build > /tmp/s.txt 2>&1; tail -20 /tmp/s.txt`
Expected: compiles; the exhaustive `case`s in `requirement`/`key` now cover `ManageLocation`/`LocationCommand`.

- [ ] **Step 4: Commit**

```bash
git add shared/src/shared/access.gleam shared/src/shared/access/policy.gleam
git commit -m "Add location.manage permission and ManageLocation policy key"
```

---

### Task 7: Server write path — fact, repository, command handler, dispatch, tag

**Files:**
- Modify: `server/src/tempo/server/fact.gleam` (new `Fact` variant)
- Modify: `server/src/tempo/server/repository.gleam` (`write` arm)
- Create: `server/src/tempo/server/location/command.gleam` (`route` + TZID guard)
- Modify: `server/src/tempo/server/command.gleam` (dispatch `route` arm)
- Modify: `server/src/tempo/server/auth.gleam` (`command_tag` arm)
- Test: `server/test/location_test.gleam` (new)

**Interfaces:**
- Consumes: `location_sql.engineer_location_upsert`, `location_sql.timezone_valid` (Task 3, exact names from generated `sql.gleam`); `operation.InvalidValue`; `fact.EngineerId`.
- Produces: `location.route(conn, LocationCommand) -> Result(Recorded, OperationError)`; `fact.EngineerLocated(engineer_id: EngineerId, country: String, region: Option(String), timezone: String, from: Date)`.

- [ ] **Step 1: Write a failing dispatch test** `server/test/location_test.gleam` (model on `financials_test.gleam`: fixture engineer, `command.dispatch_in`, assert the fact and the event_log row; assert a bad TZID is rejected). Use the rollback fixture.

```gleam
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date, July, June}
import pog
import shared/command.{LocationCommand} as gateway
import shared/location/command as location_command
import tempo/server/command
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn insert_engineer(conn: pog.Connection) -> Int {
  let row = { use id <- decode.field(0, decode.int) decode.success(id) }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row) |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

fn current_timezone(conn: pog.Connection, engineer_id: Int, as_of: Date) -> String {
  let row = { use tz <- decode.field(0, decode.string) decode.success(tz) }
  let assert Ok(returned) =
    pog.query("SELECT timezone FROM engineer_location WHERE engineer_id = $1 AND located_during @> $2::date")
    |> pog.parameter(pog.int(engineer_id))
    |> pog.parameter(pog.calendar_date(as_of))
    |> pog.returning(row) |> pog.execute(on: conn)
  let assert [tz] = returned.rows
  tz
}

pub fn set_location_records_a_dated_fact_test() {
  let tz =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      let assert Ok(_) =
        command.dispatch_in(conn, "tester", gateway.LocationCommand(
          location_command.SetEngineerLocation(
            engineer_id:, country: "GB", region: Some("GB-LND"),
            timezone: "Europe/London", effective: Date(2026, June, 1),
          )))
      current_timezone(conn, engineer_id, Date(2026, July, 1))
    })
  assert tz == "Europe/London"
}

pub fn set_location_rejects_an_unknown_timezone_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn)
      command.dispatch_in(conn, "tester", gateway.LocationCommand(
        location_command.SetEngineerLocation(
          engineer_id:, country: "GB", region: None,
          timezone: "Mars/Olympus_Mons", effective: Date(2026, June, 1),
        )))
    })
  assert outcome == Error(operation_invalid_value())
}
```

Add a small helper `fn operation_invalid_value()` returning `operation.InvalidValue` (import `tempo/server/operation`) — or assert the `Error` shape the way `financials_test` asserts typed errors; read that file and match its style.

- [ ] **Step 2: Run — confirm failure** (`cd server && gleam test > /tmp/t.txt 2>&1; tail -40 /tmp/t.txt`) — `location.route`/`fact.EngineerLocated` missing.

- [ ] **Step 3: Add the fact variant** in `fact.gleam`:

```gleam
EngineerLocated(
  engineer_id: EngineerId,
  country: String,
  region: Option(String),
  timezone: String,
  from: Date,
)
```

(ensure `gleam/option` is imported in `fact.gleam`).

- [ ] **Step 4: Add the repository `write` arm** in `repository.gleam` (import the generated module as `location_sql`):

```gleam
EngineerLocated(engineer_id: EngineerId(engineer_id), country:, region:, timezone:, from:) ->
  location_sql.engineer_location_upsert(conn, engineer_id, from, country, region, timezone, audit_id)
  |> operation.run
```

Match the surrounding arms' error-mapping (`operation.run` / `operation.try`) exactly.

- [ ] **Step 5: Write `server/src/tempo/server/location/command.gleam`** (mirror `leave/command.gleam`'s guard shape)

```gleam
//// Write handler for engineer location. `set_location` validates the TZID against
//// pg_timezone_names before recording, so an unknown zone is a clean InvalidValue.

import gleam/int
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog
import shared/command as gateway
import shared/location/command.{type LocationCommand, SetEngineerLocation}
import tempo/server/fact
import tempo/server/location/sql as location_sql
import tempo/server/operation.{type OperationError, Event, Recorded}

pub fn route(conn: pog.Connection, command: LocationCommand) -> Result(Recorded, OperationError) {
  case command {
    SetEngineerLocation(engineer_id:, country:, region:, timezone:, effective:) ->
      set_location(conn, command, engineer_id:, country:, region:, timezone:, effective:)
  }
}

pub fn set_location(
  conn: pog.Connection,
  command: LocationCommand,
  engineer_id engineer_id: Int,
  country country: String,
  region region: Option(String),
  timezone timezone: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  use valid <- operation.try(location_sql.timezone_valid(conn, timezone))
  let assert [check] = valid.rows
  case check.valid {
    False -> Error(operation.InvalidValue)
    True ->
      Ok(Recorded(
        entry: Event(
          operation: "set_engineer_location",
          summary: "Set location of engineer " <> int.to_string(engineer_id)
            <> " to " <> timezone <> " (" <> country <> ") from " <> operation.iso(effective),
          payload: gateway.encode_command(gateway.LocationCommand(command)),
        ),
        facts: [
          fact.EngineerLocated(
            engineer_id: fact.EngineerId(engineer_id),
            country:, region:, timezone:, from: effective,
          ),
        ],
      ))
  }
}
```

Confirm the generated row field is `.valid` (from `timezone_valid.sql`'s `AS valid`); adjust if Squirrel named it differently.

- [ ] **Step 6: Wire dispatch + tag** — in `command.gleam` add `LocationCommand(command) -> location.route(conn, command)` (import the concept module as `location`); in `auth.gleam` add `LocationCommand(_) -> "set_engineer_location"`.

- [ ] **Step 7: Clean-build (new Fact variant) + run green**

Run: `cd server && gleam clean && gleam build > /tmp/b.txt 2>&1; tail -20 /tmp/b.txt` then `gleam test > /tmp/t.txt 2>&1; tail -30 /tmp/t.txt`
Expected: both new tests pass. Register `location_test` in `server/test/tempo_test.gleam` if that file enumerates modules (check how existing test modules are discovered; gleeunit auto-discovers `*_test` fns, but confirm the file is picked up).

- [ ] **Step 8: Commit**

```bash
git add server/src/tempo/server/fact.gleam server/src/tempo/server/repository.gleam server/src/tempo/server/location/command.gleam server/src/tempo/server/command.gleam server/src/tempo/server/auth.gleam server/test/location_test.gleam
git commit -m "Record engineer location through the dispatch/audit seam with TZID validation"
```

---

### Task 8: Server read path — view + HTTP + router

**Files:**
- Create: `server/src/tempo/server/location/view.gleam`
- Create: `server/src/tempo/server/location/http.gleam`
- Modify: `server/src/tempo/server/web/router.gleam`
- Test: `server/test/location_test.gleam` (add read cases)

**Interfaces:**
- Consumes: `location_sql.engineer_locations(db, as_of)`, `location_sql.engineer_location_history(db, engineer_id)`; shared `location/view` types.
- Produces: `location.view.listing(context, as_of) -> Result(List(EngineerLocation), pog.QueryError)`; `location.view.history(context, engineer_id) -> Result(List(LocationRecord), pog.QueryError)`; routes `GET /api/locations?as_of=` and `GET /api/engineers/:id/location`.

- [ ] **Step 1: Write a failing read test** (against the seed; Priya relocated 2026-07-01, so her as-of timezone flips across that date)

```gleam
import tempo/server/location/view as location_view
import shared/location/view.{EngineerLocation, LocationRecord}

fn priya(entries: List(EngineerLocation)) -> EngineerLocation {
  let assert Ok(entry) = list.find(entries, fn(e) { e.name == "Priya Sharma" })
  entry
}

pub fn listing_resolves_timezone_as_of_the_date_test() {
  let assert Ok(before) = location_view.listing(test_pool.ctx(), Date(2026, June, 15))
  let assert Ok(after) = location_view.listing(test_pool.ctx(), Date(2026, July, 15))
  let assert Some(LocationRecord(timezone: tz_before, ..)) = priya(before).location
  let assert Some(LocationRecord(timezone: tz_after, ..)) = priya(after).location
  assert tz_before == "Australia/Sydney"
  assert tz_after == "Europe/London"
}
```

(imports: `gleam/list`, `gleam/option.{Some}`. Use the seed engineer name from Task 2; if the seed uses different names, match them.)

- [ ] **Step 2: Run — confirm failure** — `location_view` module missing.

- [ ] **Step 3: Write `server/src/tempo/server/location/view.gleam`** (map Squirrel rows → shared types; build `Option(LocationRecord)` from the LEFT-JOIN nullables)

```gleam
//// Reads for engineer location: the as-of listing (every engineer + their location on a
//// date, or none) and one engineer's full history.

import gleam/list
import gleam/option.{type Option, None, Some}
import pog
import shared/location/view.{type EngineerLocation, type LocationRecord, EngineerLocation, LocationRecord}
import tempo/server/context.{type Context}
import tempo/server/location/sql

pub fn listing(context: Context, as_of) -> Result(List(EngineerLocation), pog.QueryError) {
  use returned <- result_map(sql.engineer_locations(context.db, as_of))
  list.map(returned.rows, listing_row_to_shared)
}

pub fn history(context: Context, engineer_id: Int) -> Result(List(LocationRecord), pog.QueryError) {
  use returned <- result_map(sql.engineer_location_history(context.db, engineer_id))
  list.map(returned.rows, history_row_to_shared)
}
```

Add the row-mapping helpers. For the listing row, the location cols are `Option`al (LEFT JOIN); build the record only when `country` is `Some`:

```gleam
fn listing_row_to_shared(row: sql.EngineerLocationsRow) -> EngineerLocation {
  let location = case row.country {
    Some(country) ->
      Some(LocationRecord(
        country:, region: row.region, timezone: unwrap_string(row.timezone),
        valid_from: unwrap_date(row.valid_from), valid_to: row.valid_to,
      ))
    None -> None
  }
  EngineerLocation(engineer_id: row.engineer_id, name: row.name, location:)
}
```

Use whatever the generated `EngineerLocationsRow` field types are (Squirrel makes LEFT-JOIN cols `Option`). Prefer restructuring so no unwrap is needed — e.g. decode all location cols together — but if Squirrel types them individually `Option`, gate on `row.country` and pull the rest with matching `Some` patterns rather than partial unwraps. Read the generated row type and adapt. Provide `result_map` as a thin `result.map` alias or just use `result.map` inline.

- [ ] **Step 4: Write `server/src/tempo/server/location/http.gleam`** (mirror `engineer_skill/http.gleam`; the listing needs `read.engineers`, gated in the router; parse `as_of` from query)

```gleam
import gleam/int
import gleam/json
import gleam/list
import pog
import tempo/server/context.{type Context}
import tempo/server/location/view
import tempo/server/web/request
import tempo/server/web/response
import shared/location/view as location_view
import wisp

pub fn handle_listing(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case view.listing(ctx, as_of) {
        Ok(entries) ->
          response.json_response(json.array(entries, location_view.encode_engineer_location))
        Error(error) -> response.db_error_response(error)
      }
  }
}

pub fn handle_history(req: wisp.Request, ctx: Context, id_segment: String) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid engineer id '" <> id_segment <> "'")
    Ok(engineer_id) ->
      case view.history(ctx, engineer_id) {
        Ok(records) ->
          response.json_response(json.array(records, location_view.encode_location_record))
        Error(error) -> response.db_error_response(error)
      }
  }
}
```

Import `gleam/http`. Match the exact helper names in `web/request.gleam` / `web/response.gleam` (the explorer confirmed `request.date_from_query`, `response.json_response`, `response.db_error_response`).

- [ ] **Step 5: Wire the routes** in `web/router.gleam`, gated by `read.engineers` (mirror the existing engineer read routes):

```gleam
["api", "locations"] -> {
  use _principal <- guard.require(context, access.read_engineers)
  location_http.handle_listing(request, context)
}
["api", "engineers", id, "location"] -> {
  use _principal <- guard.require(context, access.read_engineers)
  location_http.handle_history(request, context, id)
}
```

Place the `["api","engineers",id,"location"]` arm alongside the existing `["api","engineers",id,"skills"]` arm; import `location_http` and ensure `access` is imported.

- [ ] **Step 6: Run green** (`cd server && gleam test > /tmp/t.txt 2>&1; tail -30 /tmp/t.txt`) — the as-of listing test passes.

- [ ] **Step 7: Commit**

```bash
git add server/src/tempo/server/location/view.gleam server/src/tempo/server/location/http.gleam server/src/tempo/server/web/router.gleam server/test/location_test.gleam
git commit -m "Serve engineer-location listing (as-of) and history endpoints"
```

---

### Task 9: Client Locations page (listing) + route + nav + styling

**Files:**
- Create: `client/src/client/page/locations.gleam`
- Modify: `client/src/client/route.gleam` (new `Locations` route)
- Modify: `client/src/client/app.gleam` (Page variant, Msg, route→page, refetch, msg routing, sidebar link)
- Create: `client/styles/locations.scss`
- Modify: `client/styles/main.scss` (`@use "locations"`)

**Interfaces:**
- Consumes: `GET /api/locations?as_of=` → `List(EngineerLocation)`; `api.get`, the as-of slider (`refetch` receives `as_of`).
- Produces: `locations.{Model, Msg, init, update, view, refetch}` (mirror the frozen page interface used by `skills`/`people`).

- [ ] **Step 1: Add the route** in `route.gleam` — `Locations` variant; `["locations"] -> Locations` in `parse`; `Locations -> "/locations"` in `to_path`.

- [ ] **Step 2: Write `client/src/client/page/locations.gleam`** — a list page modeled on the roster half of `page/people.gleam`, matching the Locations listing in `docs/prototypes/2026-07-04-scheduling.html` (columns Engineer / Location / Timezone / Offset / Since; a dimmed "No location set" row). Model holds `as_of` and a load state `LocationsLoading | LocationsLoaded(List(EngineerLocation)) | LocationsFailed(String)`; `init`/`refetch` fetch `/api/locations?as_of=`; use the stale-drop guard (compare reply `as_of`). Model the fetch on `people`'s `fetch_directory`.

```gleam
fn fetch(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/locations?as_of=" <> time.iso_date(as_of),
    decode.list(location_view.engineer_location_decoder()),
    fn(result) { Fetched(as_of:, result:) },
  )
}
```

- [ ] **Step 3: Register the page in `app.gleam`** — add `LocationsPage(locations.Model)` to `Page`; `LocationsMsg(locations.Msg)` to `Msg`; a `route.Locations ->` arm in the route→page builder (mirror `route.Skills`); a `LocationsPage` arm in `refetch_page` and in the msg-routing `case` (mirror the `SkillsMsg`/`SkillsPage` arms exactly); and a sidebar nav link to `route.Locations` labelled "Locations" (find where "Skills"/"People" links are rendered and copy the pattern, gated by `read.engineers` if links are permission-gated).

- [ ] **Step 4: Write `client/styles/locations.scss`** using existing tokens (mirror `.panel`, `.kv`, and any table styles in `components.scss`); add `@use "locations";` to `main.scss`.

- [ ] **Step 5: Build + eyeball**

Run: `bin/build > /tmp/build.txt 2>&1; tail -20 /tmp/build.txt` then `TEMPO_DB_PORT=5435 bin/serve` and open `/locations?date=2026-06-15` — Priya shows `Australia/Sydney`; at `?date=2026-07-15` she shows `Europe/London`.

- [ ] **Step 6: Commit**

```bash
git add client/src/client/page/locations.gleam client/src/client/route.gleam client/src/client/app.gleam client/styles/locations.scss client/styles/main.scss
git commit -m "Add client Locations page anchored to the as-of slider"
```

---

### Task 10: Client set-location op (write from the UI)

**Files:**
- Modify: `client/src/client/ui.gleam` (`OpKind`, `OpField`s, `OpForm` slots, `blank_op_form`, `update_op_form`, `op_command_key`, `op_verb`, `build_command`, the modal field list)
- Modify: `client/src/client/page/locations.gleam` (launch the op, submit, refetch on success)

**Interfaces:**
- Consumes: `ui.permit`, `ui.build_command`, `api.submit_operation`; the shared `SetEngineerLocation` command.
- Produces: an `OpSetLocation` op that POSTs `/api/operations`.

- [ ] **Step 1: Extend `ui.gleam`** (mirror the `OpUpdateContact` path end to end):
  - `OpKind`: add `OpSetLocation`.
  - `OpField`: add `FCountry`, `FRegion`, `FTimezone` (reuse existing `FEffective`, `FEngineerId`).
  - `OpForm`: add `country`, `region`, `timezone` slots; extend `blank_op_form` and `update_op_form`.
  - `op_command_key(OpSetLocation) -> policy.ManageLocation`.
  - `op_verb(OpSetLocation) -> "Set location"`.
  - `build_command(OpSetLocation, form)`:

```gleam
OpSetLocation -> {
  use engineer_id <- result.try(require_int(form.engineer_id, "engineer id"))
  use country <- result.try(require_text(form.country, "country"))
  use timezone <- result.try(require_text(form.timezone, "timezone"))
  use effective <- result.try(require_date(form.effective, "effective"))
  let region = case string.trim(form.region) { "" -> None  other -> Some(other) }
  Ok(gateway.LocationCommand(location_command.SetEngineerLocation(
    engineer_id:, country:, region:, timezone:, effective:,
  )))
}
```

  - Add the modal field list for `OpSetLocation`: text fields Country, Region, Timezone; date field Effective (mirror the `OpUpdateContact` field list). Import `shared/location/command as location_command`.

- [ ] **Step 2: Launch + handle in `locations.gleam`** — render a permission-gated "Set location" launcher per row (`ui.launch` with `ui.permit(permissions, own: False, kind: ui.OpSetLocation)`), pre-fill the form with the row's engineer id (and existing location if any) on `OpOpened`, and on `OperationReturned(Ok(_))` refetch (mirror `people/detail.gleam`'s op flow). Thread `permissions` into `view` the way other pages do.

- [ ] **Step 3: Clean-build (new OpKind variant) + build bundle**

Run: `cd client && gleam clean && gleam build > /tmp/c.txt 2>&1; tail -20 /tmp/c.txt` then `bin/build`
Expected: compiles; exhaustive `case`s in `ui.gleam` cover `OpSetLocation`.

- [ ] **Step 4: Manual check** — as Admin, open `/locations`, set Aisha's location to `Asia/Tokyo` effective today; the row updates after submit; an invalid TZID surfaces the 422 as a form error.

- [ ] **Step 5: Commit**

```bash
git add client/src/client/ui.gleam client/src/client/page/locations.gleam
git commit -m "Set an engineer's location from the Locations page"
```

---

### Task 11: e2e — set a location and see the as-of timezone

**Files:**
- Create: `e2e/locations.spec.js`

**Interfaces:**
- Consumes: `helpers.signInAs`, `helpers.scrubTo`, `helpers.navigateTo`, `helpers.opModal`, `helpers.confirmOp`.

- [ ] **Step 1: Write the spec** (behaviour-driven; assert visible content, re-run-safe against the never-reset e2e DB)

```js
const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, scrubTo, opModal, confirmOp } = require("./helpers");

test("an engineer's timezone reflects the as-of date across a relocation", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Locations");
  await scrubTo(page, "2026-06-15");
  await expect(page.getByRole("row", { name: /Priya Sharma/ })).toContainText("Australia/Sydney");
  await scrubTo(page, "2026-07-15");
  await expect(page.getByRole("row", { name: /Priya Sharma/ })).toContainText("Europe/London");
});

test("an admin sets an engineer's location", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Locations");
  // open the Set location op for a known engineer, fill Timezone + Effective, confirm,
  // then assert the row shows the new TZID. Use the op modal helpers; match the field
  // labels rendered in Task 10.
});
```

Fill in the second test's body against the actual rendered labels/roles. Keep it re-run-safe (setting a location is idempotent for a given effective date, but prefer a far-future effective date and assert only the resulting row text).

- [ ] **Step 2: Run e2e** (rebuilds the bundle + migrates + seeds the e2e DB)

Run: `TEMPO_DB_PORT=5435 bin/e2e locations.spec.js > /tmp/e2e.txt 2>&1; tail -40 /tmp/e2e.txt`
Expected: both tests pass. If the relocation dates differ from the seed, align the spec to the seeded spans.

- [ ] **Step 3: Commit**

```bash
git add e2e/locations.spec.js
git commit -m "e2e: engineer timezone tracks the as-of date across a relocation"
```

---

## Self-Review

- **Spec coverage:** Layer A of the design (the `engineer_location` table, TZID validation, as-of resolution, the Locations listing surface, set-location write) is covered by Tasks 1–11. The engineer-detail location panel with a full history timeline (design Frontend row "Engineer location panel") is partially covered — the history endpoint ships (Task 8) but the client renders history only if added to the Locations page; a richer per-engineer panel on the People screen is deferred to a later slice and is not required to prove the primitive. Public holidays, working hours, meetings, and the finder are Phases B–D, out of scope here.
- **Types consistency:** `LocationRecord`/`EngineerLocation` field names are identical across `shared/location/view.gleam`, the server view mapper, and the client decoder. `SetEngineerLocation` arg names match across `shared/location/command.gleam`, `fact.EngineerLocated`, `location/command.gleam`, and `ui.build_command`. `location.manage` string matches between `access.gleam`, `policy.gleam`, and `rbac_seed.sql`.
- **Squirrel names:** Tasks 7–8 depend on generated fn/row names from Task 3; each task says to read the generated `sql.gleam` and use exact names (Squirrel may name nullable/`AS`-aliased columns idiosyncratically). This is the one place to verify against generated code rather than assume.
- **Ordering:** Migration (1) → seed (2) → Squirrel (3) → shared (4–6) → server (7–8) → client (9–10) → e2e (11). Task 2's `rbac_seed` grant uses only a string, so it does not depend on Task 6's constant compiling.
