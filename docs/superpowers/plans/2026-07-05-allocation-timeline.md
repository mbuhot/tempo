# Project Allocation Timeline (Schedule page) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Schedule page showing every active project's engineer allocations over 12 weekly columns with per-requirement gap rows, plus a what-if scenario system that previews draft operations through the real write seam inside a rolled-back transaction and applies them as one batch.

**Architecture:** A new `schedule` read-model concept (SQL series via `generate_series`, view assembly, Wisp handlers) plus a preview/apply executor built on `command.dispatch_in` with per-op savepoints. One new write command: `RescheduleProject`, nested in `EngagementCommand` (existing policy/auth wildcards cover it), whose repository write is a single multi-CTE cascade statement (immediate PERIOD FKs check at statement end). Client is a new self-contained MVU page with a read-only timeline grid and an aside inspector that produces draft `Command`s.

**Tech Stack:** Gleam 1.17 (Erlang + JS), PostgreSQL 19beta1, Squirrel, Wisp, pog, Lustre, gleeunit, Playwright.

**Spec:** `docs/superpowers/specs/2026-07-04-allocation-timeline-design.md`. **UI reference:** `docs/prototypes/2026-07-05-allocation-timeline.html`.

## Global Constraints

- **DB port is 5435** (5434 Docker proxy is wedged). Export `TEMPO_DB_PORT=5435` for `bin/migrate`/`bin/test`/`bin/serve`. `bin/squirrel` hardcodes its URL — run as `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo bin/squirrel`.
- **No migration in this plan** — every table already exists. Squirrel regen is still required after adding `.sql` files.
- **Clean-build after union changes**: after extending `EngagementCommand`, `Fact`, or `OperationError`, run `gleam clean && gleam build` in the affected package — incremental builds can mask inexhaustive `case`s.
- **TDD, red then green**: stub with `todo`, write one failing test, confirm it fails on assertion/`todo` (never a compile error), implement minimally, confirm green, commit.
- **Never pipe test output through `head`/`grep`/`tail` in the same command** — redirect to a file (`bin/test > /tmp/test.log 2>&1`) then read the file.
- **Assertions**: `assert expr == expected` with exact deterministic values; base-seed "now" is **2026-06-15** (a Monday). No conditional assertions. No inline comments in code or tests; SQL files get only the standard header doc comment.
- **Gleam server tests** run against `tempo_test` via `TEMPO_DB_PORT=5435 bin/test` (base seed only). **e2e** runs against `tempo_e2e` via `TEMPO_DB_PORT=5435 bin/e2e` (base + financials seed; e2e DB is append-only across runs — applied writes must be idempotent, so the e2e apply test uses `RescheduleProject` to a fixed window).
- **Commit after each green task**; list files explicitly (never `git add -A`). No Claude/Anthropic attribution in commit messages.
- Squirrel decodes `numeric` as Float via `pog.numeric_decoder()` — fine for fractions/quantities/proficiencies (ratios stay Float). Money would need `::text` (no money columns in this plan).
- Never select a bare `upper(range)` on a possibly open-ended range. All ranges read here (`project_run.active_during`, `allocation.allocated_during`, requirement ranges) are bounded by PERIOD-FK containment in bounded parents, so `upper()` is safe on those specific tables.
- Base-seed facts used by tests (from `server/priv/seed/base_seed.sql`): engineers 1=Priya Sharma (L5), 2=Marcus Chen (L4, promoted L5 from 2026-07-01), 3=Aisha Okafor (L6). Projects 100=Ledger Migration (run 2024-01-01..2027-01-01, capability demand: Payments Platform target L3 ×2.00 and Frontend Delivery target L1 ×1.00, both 2026-01-10..2027-01-01), 200=Inventory Sync, 300=Data Platform (Marcus 1.0 + Aisha 1.0), 400=Platform Telemetry (no allocations), 500=Edge Analytics (run 2026-06-01..2027-01-01, no allocations, `project_requirement`: 2×L3 + 1×L4 + 0.5×L5 over 2026-08-01..2027-01-01). Allocations: Priya→100 @0.5 and →200 @0.5 (both to 2027-01-01). Aisha annual leave 2026-06-08..2026-06-22. Priya timesheets on 100 and 200 dated 2026-06-09. Contracts: 10 (Northwind, 2024-01-01..2027-01-01) covers 100/200; 20 (Globex, 2025-01-01..2027-01-01) covers 300/400; 30 (Initech, 2026-06-01..2027-01-01) covers 500. Priya's Payments Platform rollup as-of 2026-06-15 = (4·3+3·3+4·2+3·1)/9 = 32/9 ≈ 3.5556; her Frontend Delivery rollup = (2·3+0·2+3·1)/6 = 1.5.

## File Structure

**New files:**
- `server/src/tempo/server/project/sql/project_reschedule_pins.sql` — guard counts (runs, timesheets, invoices).
- `server/src/tempo/server/project/sql/project_reschedule.sql` — the single-statement delta-shift cascade.
- `server/src/tempo/server/schedule/sql/{schedule_weeks,schedule_projects,schedule_lanes,schedule_totals,schedule_level_gaps,schedule_capability_gaps,schedule_candidates}.sql` + generated `schedule/sql.gleam`.
- `server/src/tempo/server/schedule/view.gleam` — timeline assembly (cells, gaps, seats, capability chart).
- `server/src/tempo/server/schedule/executor.gleam` — preview/apply batch executor with savepoints.
- `server/src/tempo/server/schedule/http.gleam` — GET schedule, GET candidates, POST preview, POST apply.
- `shared/src/shared/schedule/view.gleam` — Schedule/PreviewResult types + codecs.
- `server/test/reschedule_test.gleam`, `server/test/schedule_test.gleam`, `server/test/schedule_executor_test.gleam`, `shared/test/schedule_view_test.gleam`.
- `client/src/client/page/schedule.gleam`, `client/styles/schedule.scss`, `e2e/schedule.spec.js`.

**Modified files:** `shared/src/shared/engagement/command.gleam`, `server/src/tempo/server/fact.gleam`, `server/src/tempo/server/operation.gleam`, `server/src/tempo/server/repository.gleam`, `server/src/tempo/server/engagement/command.gleam`, `server/src/tempo/server/web/operations.gleam`, `server/src/tempo/server/web/router.gleam`, `server/src/tempo/server/project/sql.gleam` (regenerated), `server/test/codec_test.gleam`, `client/src/client/route.gleam`, `client/src/client/app.gleam`, `client/src/client/api.gleam`, `client/styles/main.scss`.

**Deliberately untouched:** `shared/src/shared/command.gleam`, `shared/src/shared/access/policy.gleam`, `server/src/tempo/server/auth.gleam`, `server/src/tempo/server/command.gleam` — `RescheduleProject` nests inside `EngagementCommand`, whose wildcard arms (`EngagementCommand(_) -> ManageEngagement` / `"manage_engagement"`) already route and gate it. No seed changes — the base seed already carries the demo gaps (projects 100 and 500).

---

### Task 1: `RescheduleProject` shared command + codec

**Files:**
- Modify: `shared/src/shared/engagement/command.gleam`
- Test: `server/test/codec_test.gleam`

**Interfaces:**
- Produces: `shared/engagement/command.RescheduleProject(project_id: Int, valid_from: Date, valid_to: Date)`, JSON op tag `"reschedule_project"`. Later tasks build it as `command.EngagementCommand(engagement_command.RescheduleProject(...))`.

- [x] **Step 1: Write the failing round-trip test**

Open `server/test/codec_test.gleam`, find the existing command round-trip tests (encode → `json.to_string` → parse with `command.grouped_command_decoder()` style — copy the exact harness the neighbouring engagement test uses), and add:

```gleam
pub fn reschedule_project_codec_round_trip_test() {
  let original =
    command.EngagementCommand(engagement_command.RescheduleProject(
      project_id: 500,
      valid_from: calendar.Date(2026, calendar.September, 7),
      valid_to: calendar.Date(2027, calendar.January, 1),
    ))
  assert round_trip(original) == Ok(original)
}
```

(`round_trip` is whatever helper the file already uses for other commands — reuse it verbatim; if the file's helper is named differently, match it.)

- [x] **Step 2: Run to verify it fails as a compile-then-todo failure**

The variant does not exist yet, so first add the variant stub so the test compiles (TDD in Gleam: the union change is the stub):

In `shared/src/shared/engagement/command.gleam` add to the union:

```gleam
  /// Move a project's whole plan to a new [from, to) run window.
  RescheduleProject(project_id: Int, valid_from: Date, valid_to: Date)
```

and add `RescheduleProject` to any `import`/re-export list in the same file if present. Add a temporary `todo` arm in `encode` and `decoder` so it compiles:

```gleam
    RescheduleProject(..) -> todo
```

Run: `cd server && gleam test > /tmp/t1.log 2>&1; tail -5 /tmp/t1.log`
Expected: FAIL — the round-trip test panics on `todo` (a runtime todo, never a compile error).

- [x] **Step 3: Implement the codec**

In `encode`:

```gleam
    RescheduleProject(project_id:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("reschedule_project")),
        #("project_id", json.int(project_id)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
```

In `decoder(op)` add a case:

```gleam
    "reschedule_project" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(RescheduleProject(project_id:, valid_from:, valid_to:))
      })
```

- [x] **Step 4: Clean-build both packages, run tests**

Run: `cd shared && gleam clean && gleam build && cd ../server && gleam clean && TEMPO_DB_PORT=5435 ../bin/test > /tmp/t1.log 2>&1; tail -5 /tmp/t1.log`
Expected: PASS. The compiler will name any remaining inexhaustive site (there should be none server-side — `engagement/command.gleam`'s `route` gets its arm in Task 2; if the build fails there now, add a `RescheduleProject(..) -> todo` arm and leave it red-free by keeping the arm compiling with `todo` only until Task 2).

Note: if `server/src/tempo/server/engagement/command.gleam`'s `route` case fails to compile at this step (it will — the case is exhaustive), add the stub arm now:

```gleam
    RescheduleProject(project_id:, valid_from:, valid_to:) ->
      reschedule_project(conn, command, project_id:, valid_from:, valid_to:)
```

with

```gleam
pub fn reschedule_project(
  conn: pog.Connection,
  command: EngagementCommand,
  project_id project_id: Int,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  todo
}
```

The codec test passes; the `todo` handler is exercised only in Task 2's tests.

- [x] **Step 5: Commit**

```bash
git add shared/src/shared/engagement/command.gleam server/src/tempo/server/engagement/command.gleam server/test/codec_test.gleam
git commit -m "Add RescheduleProject engagement command with JSON codec

Nested in EngagementCommand so the existing ManageEngagement policy and
manage_engagement audit tag cover it; server route arm stubbed."
```

---

### Task 2: Reschedule write path — fact, guards, cascade SQL, repository arm

**Files:**
- Create: `server/src/tempo/server/project/sql/project_reschedule_pins.sql`
- Create: `server/src/tempo/server/project/sql/project_reschedule.sql`
- Modify: `server/src/tempo/server/project/sql.gleam` (squirrel regen — never hand-edit)
- Modify: `server/src/tempo/server/fact.gleam`, `server/src/tempo/server/operation.gleam`, `server/src/tempo/server/repository.gleam`, `server/src/tempo/server/engagement/command.gleam`, `server/src/tempo/server/web/operations.gleam`
- Test: `server/test/reschedule_test.gleam`

**Interfaces:**
- Consumes: `RescheduleProject` from Task 1; existing `command.dispatch_in(conn, actor, command)`.
- Produces: `fact.ProjectRescheduled(project_id: ProjectId, from: Date, to: Date)`; `operation.ProjectPinned` error variant; SQL fns `project_sql.project_reschedule_pins(db, project_id)` returning one row `ProjectReschedulePinsRow(runs: Int, timesheets: Int, invoices: Int)` and `project_sql.project_reschedule(db, project_id, from, to, audit_id)`.

**Semantics (from spec):** move the whole plan by `delta = new_from − old_from`: run, requirements, capabilities, allocations all shift; shifted child ranges clamp to the new window; a child whose clamped range is empty is dropped. Guards reject: no run / multiple runs (`NoSuchVersion` / `InvalidValue`), logged timesheets or invoice subjects (`ProjectPinned`). A run landing outside its contract term rejects via the existing `_within_` containment constraint → `ContainmentViolated`.

- [x] **Step 1: Write the failing tests**

Create `server/test/reschedule_test.gleam`. Copy the exact harness from `server/test/location_test.gleam`: the `rolling_back` helper, imports (`pog`, `gleam/dynamic/decode`, `tempo/server/command`, `tempo/server/operation`, `shared/command as gateway`, `test_pool`), and the raw-query helper style. Base-seed ids are stable (Global Constraints).

```gleam
import gleam/dynamic/decode
import gleam/time/calendar.{Date}
import pog
import shared/command as gateway
import shared/engagement/command as engagement_command
import tempo/server/command
import tempo/server/operation
import test_pool

fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let assert Error(pog.TransactionRolledBack(value)) =
    pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  value
}

fn reschedule(project_id: Int, from: Date, to: Date) -> gateway.Command {
  gateway.EngagementCommand(engagement_command.RescheduleProject(
    project_id:,
    valid_from: from,
    valid_to: to,
  ))
}

fn range_rows(conn: pog.Connection, sql: String) -> List(#(String, String)) {
  let row = {
    use a <- decode.field(0, decode.string)
    use b <- decode.field(1, decode.string)
    decode.success(#(a, b))
  }
  let assert Ok(returned) =
    pog.query(sql) |> pog.returning(row) |> pog.execute(on: conn)
  returned.rows
}

pub fn reschedule_shifts_run_and_children_test() {
  let #(run, requirements) =
    rolling_back(fn(conn) {
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          reschedule(
            500,
            Date(2026, calendar.September, 7),
            Date(2027, calendar.January, 1),
          ),
        )
      let run =
        range_rows(
          conn,
          "SELECT lower(active_during)::text, upper(active_during)::text
           FROM project_run WHERE project_id = 500",
        )
      let requirements =
        range_rows(
          conn,
          "SELECT lower(required_during)::text, upper(required_during)::text
           FROM project_requirement WHERE project_id = 500 AND level = 3",
        )
      #(run, requirements)
    })
  assert run == [#("2026-09-07", "2027-01-01")]
  assert requirements == [#("2026-11-07", "2027-01-01")]
}
```

Project 500's run moves 2026-06-01 → 2026-09-07 (delta = +98 days); its L3 requirement 2026-08-01..2027-01-01 shifts to 2026-11-07..2027-04-09 and clamps to the new run end 2027-01-01.

```gleam
pub fn reschedule_drops_children_shifted_past_the_window_test() {
  let requirements =
    rolling_back(fn(conn) {
      let assert Ok(_) =
        command.dispatch_in(
          conn,
          "tester",
          reschedule(
            500,
            Date(2026, calendar.June, 15),
            Date(2026, calendar.July, 15),
          ),
        )
      range_rows(
        conn,
        "SELECT lower(required_during)::text, upper(required_during)::text
         FROM project_requirement WHERE project_id = 500",
      )
    })
  assert requirements == []
}
```

(Delta = +14 days shifts the requirements to start 2026-08-15, past the new run end 2026-07-15 — every clamped range is empty, so all three requirement rows drop. The window [2026-06-15, 2026-07-15) stays inside contract 30's term 2026-06-01..2027-01-01, so containment holds.)

```gleam
pub fn reschedule_rejects_a_project_with_logged_time_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          100,
          Date(2024, calendar.February, 1),
          Date(2027, calendar.January, 1),
        ),
      )
    })
  assert outcome == Error(operation.ProjectPinned)
}

pub fn reschedule_rejects_a_run_outside_the_contract_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          500,
          Date(2026, calendar.May, 1),
          Date(2026, calendar.August, 1),
        ),
      )
    })
  assert outcome == Error(operation.ContainmentViolated)
}

pub fn reschedule_rejects_an_unknown_project_test() {
  let outcome =
    rolling_back(fn(conn) {
      command.dispatch_in(
        conn,
        "tester",
        reschedule(
          999,
          Date(2026, calendar.July, 1),
          Date(2026, calendar.August, 1),
        ),
      )
    })
  assert outcome == Error(operation.NoSuchVersion)
}
```

(Project 100 has Priya's timesheets and project 500's contract 30 starts 2026-06-01, so 2026-05-01 violates `_within_` containment. If `operation.gleam`'s existing variants differ in name — e.g. `NoSuchVersion` — match the real names; `ProjectPinned` is new in Step 3.)

- [x] **Step 2: Run to verify failures**

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t2.log 2>&1; tail -20 /tmp/t2.log`
Expected: FAIL — first on `operation.ProjectPinned` not existing (add the variant stub, re-run) then on the `todo` in `reschedule_project`.

- [x] **Step 3: Add the `ProjectPinned` error variant**

In `server/src/tempo/server/operation.gleam` add to the `OperationError` union (alongside the other domain guards like `EngineerNotEmployed`):

```gleam
  /// The project has logged timesheets or issued invoices; its schedule is pinned.
  ProjectPinned
```

Run `cd server && gleam clean && gleam build > /tmp/build.log 2>&1; tail -20 /tmp/build.log` — the compiler names every inexhaustive `case`: at minimum `web/operations.gleam`'s `error_response`. Add there (409, matching the file's existing conflict-style arms — copy the JSON body shape its neighbours use):

```gleam
    operation.ProjectPinned ->
      conflict_response("project has logged time or invoices; reschedule is pinned")
```

(Use the file's actual local helper for 409/conflict bodies — read the neighbouring arms and mirror them exactly.)

- [x] **Step 4: Write the two SQL files and regenerate squirrel**

`server/src/tempo/server/project/sql/project_reschedule_pins.sql`:

```sql
-- project_reschedule_pins.sql — reschedule guard counts for one project: how many
-- run rows it has, and how many timesheet / invoice_subject rows pin its schedule.
-- $1 = project_id.
SELECT
  (SELECT count(*) FROM project_run WHERE project_id = $1)::int AS runs,
  (SELECT count(*) FROM timesheet WHERE project_id = $1)::int AS timesheets,
  (SELECT count(*) FROM invoice_subject WHERE project_id = $1)::int AS invoices;
```

`server/src/tempo/server/project/sql/project_reschedule.sql`:

```sql
-- project_reschedule.sql — move a project's whole plan by delta = $2 - lower(run):
-- delete the run and its allocation / requirement / capability children, then
-- re-insert all of them shifted by delta and clamped to the new [$2, $3) window
-- (a child whose clamped range is empty is dropped). One statement, so the
-- immediate PERIOD FKs check the final state at statement end; a run landing
-- outside its contract term rejects via project_within_contract. $1 = project_id,
-- $2 = new from, $3 = new to, $4 = audit_id.
WITH old_run AS (
  DELETE FROM project_run WHERE project_id = $1
  RETURNING contract_id, ($2::date - lower(active_during)) AS delta
),
old_allocation AS (
  DELETE FROM allocation WHERE project_id = $1
  RETURNING engineer_id, fraction, allocated_during
),
old_requirement AS (
  DELETE FROM project_requirement WHERE project_id = $1
  RETURNING level, quantity, required_during
),
old_capability AS (
  DELETE FROM project_capability WHERE project_id = $1
  RETURNING capability_id, target_level, quantity, required_during
),
new_run AS (
  INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
  SELECT $1, contract_id, daterange($2::date, $3::date, '[)'), $4 FROM old_run
),
new_allocation AS (
  INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
  SELECT engineer_id, $1, fraction,
         daterange(greatest(lower(allocated_during) + delta, $2::date),
                   least(upper(allocated_during) + delta, $3::date), '[)'),
         $4
  FROM old_allocation, old_run
  WHERE greatest(lower(allocated_during) + delta, $2::date)
      < least(upper(allocated_during) + delta, $3::date)
),
new_requirement AS (
  INSERT INTO project_requirement (project_id, level, quantity, required_during, audit_id)
  SELECT $1, level, quantity,
         daterange(greatest(lower(required_during) + delta, $2::date),
                   least(upper(required_during) + delta, $3::date), '[)'),
         $4
  FROM old_requirement, old_run
  WHERE greatest(lower(required_during) + delta, $2::date)
      < least(upper(required_during) + delta, $3::date)
)
INSERT INTO project_capability (project_id, capability_id, target_level, quantity, required_during, audit_id)
SELECT $1, capability_id, target_level, quantity,
       daterange(greatest(lower(required_during) + delta, $2::date),
                 least(upper(required_during) + delta, $3::date), '[)'),
       $4
FROM old_capability, old_run
WHERE greatest(lower(required_during) + delta, $2::date)
    < least(upper(required_during) + delta, $3::date);
```

Run: `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo bin/squirrel > /tmp/squirrel.log 2>&1; tail -5 /tmp/squirrel.log`
Expected: regeneration succeeds; `server/src/tempo/server/project/sql.gleam` gains `project_reschedule_pins` (row type with `runs: Int, timesheets: Int, invoices: Int`) and `project_reschedule(db, arg_1: Int, arg_2: Date, arg_3: Date, arg_4: Int)`.

- [x] **Step 5: Add the fact and its repository write**

`server/src/tempo/server/fact.gleam`, after `ProjectRun`:

```gleam
  /// A project's whole plan moved to a new [from, to) run window.
  ProjectRescheduled(project_id: ProjectId, from: Date, to: Date)
```

`server/src/tempo/server/repository.gleam` — import `ProjectRescheduled` in the `fact.{...}` list, add a `write` arm after the `ProjectRun` arm:

```gleam
    ProjectRescheduled(project_id: ProjectId(project_id), from:, to:) ->
      record_reschedule(conn, audit_id, project_id, from, to)
```

and the helper alongside `record_requirement`:

```gleam
/// Record a reschedule: guard that exactly one run exists and nothing pins the
/// schedule (timesheets, invoices), then run the one-statement cascade that
/// delta-shifts the run and its children, clamped to the new window.
fn record_reschedule(
  conn: pog.Connection,
  audit_id: Int,
  project_id: Int,
  from: Date,
  to: Date,
) -> Result(Nil, OperationError) {
  use pins <- operation.try(project_sql.project_reschedule_pins(
    conn,
    project_id,
  ))
  let assert [row] = pins.rows
  use _ <- result.try(case row.runs, row.timesheets + row.invoices {
    0, _ -> Error(operation.NoSuchVersion)
    1, 0 -> Ok(Nil)
    1, _ -> Error(operation.ProjectPinned)
    _, _ -> Error(operation.InvalidValue)
  })
  project_sql.project_reschedule(conn, project_id, from, to, audit_id)
  |> operation.run
}
```

(If `operation.gleam` has no `InvalidValue` variant, use the closest existing generic-rejection variant the file defines — the compiler and the file's doc comments will name it. Do not invent a second new variant.)

- [x] **Step 6: Implement the engagement handler**

Replace the Task 1 `todo` body in `server/src/tempo/server/engagement/command.gleam` (import `RescheduleProject` in the `shared/engagement/command.{...}` list):

```gleam
pub fn reschedule_project(
  conn: pog.Connection,
  command: EngagementCommand,
  project_id project_id: Int,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  let _ = conn
  Ok(
    Recorded(
      entry: Event(
        operation: "reschedule_project",
        summary: "Reschedule project " <> int.to_string(project_id),
        payload: gateway.encode_command(EngagementCommand(command)),
      ),
      facts: [
        fact.ProjectRescheduled(
          project_id: fact.ProjectId(project_id),
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}
```

(Match the file's existing `Event` construction exactly — if its `summary` style includes a date span helper, mirror the `start_project` handler's summary shape.)

- [x] **Step 7: Clean-build, run tests**

Run: `cd server && gleam clean && TEMPO_DB_PORT=5435 ../bin/test > /tmp/t2.log 2>&1; tail -10 /tmp/t2.log`
Expected: PASS, all reschedule tests green.

- [x] **Step 8: Commit**

```bash
git add server/src/tempo/server/project/sql/project_reschedule_pins.sql server/src/tempo/server/project/sql/project_reschedule.sql server/src/tempo/server/project/sql.gleam server/src/tempo/server/fact.gleam server/src/tempo/server/operation.gleam server/src/tempo/server/repository.gleam server/src/tempo/server/engagement/command.gleam server/src/tempo/server/web/operations.gleam server/test/reschedule_test.gleam
git commit -m "Record ProjectRescheduled via a one-statement delta-shift cascade

Guards (single run, no timesheets/invoices -> ProjectPinned) then a
multi-CTE delete-and-reinsert that shifts run, allocations, requirements
and capabilities by the delta, clamped to the new window; immediate
PERIOD FKs validate the final state at statement end."
```

---

### Task 3: Shared schedule view types + codecs

**Files:**
- Create: `shared/src/shared/schedule/view.gleam`
- Test: `shared/test/schedule_view_test.gleam`

**Interfaces:**
- Produces (consumed by Tasks 4–8; signatures verbatim):

```gleam
pub type CellState {
  OutsideRun
  Idle
  Working(fraction: Float, over_allocated: Bool)
  OnLeave
}

pub type EngineerLane {
  EngineerLane(engineer_id: Int, name: String, level: Int, cells: List(CellState))
}

pub type LineKind {
  LevelLine(level: Int)
  CapabilityLine(capability_id: Int, name: String, target_level: Int)
}

pub type RequirementLine {
  RequirementLine(kind: LineKind, gaps: List(Float))
}

pub type Seat {
  FilledSeat(level: Int, engineer_id: Int, name: String, fraction: Float)
  OpenSeat(level: Int, fraction: Float)
}

pub type CapabilityCoverage {
  CapabilityCoverage(capability_id: Int, name: String, target_level: Int, team_proficiency: Float)
}

pub type ProjectSchedule {
  ProjectSchedule(
    project_id: Int,
    title: String,
    client: String,
    run_from: Date,
    run_to: Date,
    lanes: List(EngineerLane),
    lines: List(RequirementLine),
    team: List(Seat),
    capabilities: List(CapabilityCoverage),
    annotation: Option(String),
  )
}

pub type Schedule {
  Schedule(as_of: Date, weeks: List(Date), projects: List(ProjectSchedule))
}

pub type OperationOutcome {
  OperationApplied
  OperationRejected(detail: String)
}

pub type PreviewResult {
  PreviewResult(schedule: Schedule, outcomes: List(OperationOutcome))
}

pub type Candidate {
  Candidate(engineer_id: Int, name: String, level: Int, proficiency: Float, free: Float, commitments: String)
}

pub fn encode_schedule(schedule: Schedule) -> Json
pub fn schedule_decoder() -> Decoder(Schedule)
pub fn encode_preview_result(result: PreviewResult) -> Json
pub fn preview_result_decoder() -> Decoder(PreviewResult)
pub fn candidate_decoder() -> Decoder(Candidate)
pub fn encode_candidate(candidate: Candidate) -> Json
```

- [x] **Step 1: Write the failing round-trip test**

`shared/test/schedule_view_test.gleam` (follow `shared/test/workflow_view_test.gleam`'s harness style — encode to string, decode with `json.parse`):

```gleam
import gleam/json
import gleam/option.{None, Some}
import gleam/time/calendar.{Date}
import shared/schedule/view

fn round_trip_schedule(schedule: view.Schedule) -> Result(view.Schedule, _) {
  view.encode_schedule(schedule)
  |> json.to_string
  |> json.parse(view.schedule_decoder())
}

pub fn schedule_codec_round_trip_test() {
  let schedule =
    view.Schedule(
      as_of: Date(2026, calendar.June, 15),
      weeks: [Date(2026, calendar.June, 15), Date(2026, calendar.June, 22)],
      projects: [
        view.ProjectSchedule(
          project_id: 500,
          title: "Edge Analytics",
          client: "Initech Systems",
          run_from: Date(2026, calendar.June, 1),
          run_to: Date(2027, calendar.January, 1),
          lanes: [
            view.EngineerLane(engineer_id: 1, name: "Priya Sharma", level: 5, cells: [
              view.Working(fraction: 0.5, over_allocated: True),
              view.OnLeave,
            ]),
            view.EngineerLane(engineer_id: 2, name: "Marcus Chen", level: 4, cells: [
              view.OutsideRun,
              view.Idle,
            ]),
          ],
          lines: [
            view.RequirementLine(kind: view.LevelLine(level: 3), gaps: [2.0, 0.0]),
            view.RequirementLine(
              kind: view.CapabilityLine(capability_id: 1, name: "Payments Platform", target_level: 3),
              gaps: [1.5, 1.5],
            ),
          ],
          team: [
            view.FilledSeat(level: 3, engineer_id: 1, name: "Priya Sharma", fraction: 0.5),
            view.OpenSeat(level: 3, fraction: 1.0),
            view.OpenSeat(level: 3, fraction: 0.5),
          ],
          capabilities: [
            view.CapabilityCoverage(capability_id: 1, name: "Payments Platform", target_level: 3, team_proficiency: 3.5),
          ],
          annotation: Some("outside contract term"),
        ),
      ],
    )
  assert round_trip_schedule(schedule) == Ok(schedule)
}

pub fn preview_result_codec_round_trip_test() {
  let result =
    view.PreviewResult(
      schedule: view.Schedule(as_of: Date(2026, calendar.June, 15), weeks: [], projects: []),
      outcomes: [view.OperationApplied, view.OperationRejected(detail: "overlapping fact")],
    )
  let round_tripped =
    view.encode_preview_result(result)
    |> json.to_string
    |> json.parse(view.preview_result_decoder())
  assert round_tripped == Ok(result)
}

pub fn candidate_codec_round_trip_test() {
  let candidate =
    view.Candidate(engineer_id: 3, name: "Aisha Okafor", level: 6, proficiency: 2.9, free: 0.0, commitments: "Data Platform 100%")
  let round_tripped =
    view.encode_candidate(candidate)
    |> json.to_string
    |> json.parse(view.candidate_decoder())
  assert round_tripped == Ok(candidate)
}
```

- [x] **Step 2: Stub the module with `todo`, confirm the tests fail on `todo`**

Create `shared/src/shared/schedule/view.gleam` with all the types from the Interfaces block plus codec fns whose bodies are `todo`. Run: `cd shared && gleam test > /tmp/t3.log 2>&1; tail -5 /tmp/t3.log` — expected: FAIL on `todo`.

- [x] **Step 3: Implement the codecs**

Follow `shared/src/shared/board/view.gleam`'s conventions exactly: dates via `wire.encode_date` / `wire.date_decoder()`; tagged unions via a `"status"`/`"kind"` discriminator string field. Full implementation:

```gleam
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

fn encode_cell(cell: CellState) -> Json {
  case cell {
    OutsideRun -> json.object([#("state", json.string("outside_run"))])
    Idle -> json.object([#("state", json.string("idle"))])
    OnLeave -> json.object([#("state", json.string("on_leave"))])
    Working(fraction:, over_allocated:) ->
      json.object([
        #("state", json.string("working")),
        #("fraction", json.float(fraction)),
        #("over_allocated", json.bool(over_allocated)),
      ])
  }
}

fn cell_decoder() -> Decoder(CellState) {
  use state <- decode.field("state", decode.string)
  case state {
    "outside_run" -> decode.success(OutsideRun)
    "idle" -> decode.success(Idle)
    "on_leave" -> decode.success(OnLeave)
    "working" -> {
      use fraction <- decode.field("fraction", wire.lenient_float_decoder())
      use over_allocated <- decode.field("over_allocated", decode.bool)
      decode.success(Working(fraction:, over_allocated:))
    }
    _ -> decode.failure(Idle, "CellState")
  }
}
```

and analogous encode/decoder pairs for `EngineerLane`, `LineKind` (`"kind": "level" | "capability"`), `RequirementLine` (gaps as `json.array(gaps, json.float)` / `decode.list(wire.lenient_float_decoder())`), `Seat` (`"kind": "filled" | "open"`), `CapabilityCoverage`, `ProjectSchedule` (`annotation` via `json.nullable(annotation, json.string)` / `decode.optional_field`-style matching how board encodes options — copy its exact optional idiom), `Schedule`, `OperationOutcome` (`"outcome": "applied" | "rejected"`), `PreviewResult`, `Candidate`. Every float field decodes with `wire.lenient_float_decoder()` (ints arriving where floats are expected must not fail — same reason allocation commands use it).

- [x] **Step 4: Run shared tests**

Run: `cd shared && gleam test > /tmp/t3.log 2>&1; tail -5 /tmp/t3.log`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add shared/src/shared/schedule/view.gleam shared/test/schedule_view_test.gleam
git commit -m "Add shared schedule view types and JSON codecs

Schedule/ProjectSchedule/EngineerLane/CellState timeline shape,
requirement lines with weekly gaps, team seats, capability coverage,
preview outcomes and candidates; round-tripped codecs."
```

---

### Task 4: Schedule read model — SQL, view assembly, GET endpoint

**Files:**
- Create: `server/src/tempo/server/schedule/sql/schedule_weeks.sql`, `schedule_projects.sql`, `schedule_lanes.sql`, `schedule_totals.sql`, `schedule_level_gaps.sql`, `schedule_capability_gaps.sql`
- Create: `server/src/tempo/server/schedule/sql.gleam` (squirrel-generated)
- Create: `server/src/tempo/server/schedule/view.gleam`, `server/src/tempo/server/schedule/http.gleam`
- Modify: `server/src/tempo/server/web/router.gleam`
- Test: `server/test/schedule_test.gleam`

**Interfaces:**
- Consumes: shared types from Task 3.
- Produces: `schedule_view.timeline(db: pog.Connection, as_of: Date) -> Result(shared_schedule.Schedule, pog.QueryError)` — note it takes a **Connection**, never a Context, so Task 6's executor can run the same read inside its transaction (the pnl in-transaction precedent: reads on the tx connection stay serial; the `async` fan-out helper is for pool reads only and is NOT used here). Also `http.handle(req, ctx)` for `GET /api/schedule?as_of=`.

Every query starts from the same 12-week series; 2026-06-15 is a Monday so `date_trunc('week', ...)` anchors exactly on the as-of date in tests.

- [x] **Step 1: Write the failing view test**

`server/test/schedule_test.gleam`:

```gleam
import gleam/list
import gleam/option.{None}
import gleam/time/calendar.{Date}
import shared/schedule/view as shared_schedule
import tempo/server/schedule/view as schedule_view
import test_pool

pub fn timeline_buckets_twelve_weeks_from_the_as_of_monday_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  assert list.length(schedule.weeks) == 12
  assert list.first(schedule.weeks) == Ok(Date(2026, calendar.June, 15))
  assert list.last(schedule.weeks) == Ok(Date(2026, calendar.August, 31))
}

pub fn timeline_lists_projects_overlapping_the_window_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let titles = list.map(schedule.projects, fn(project) { project.title })
  assert titles
    == [
      "Data Platform", "Edge Analytics", "Inventory Sync", "Ledger Migration",
      "Platform Telemetry",
    ]
}

pub fn a_leave_week_renders_on_leave_and_counts_zero_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(data_platform) =
    list.find(schedule.projects, fn(project) { project.project_id == 300 })
  let assert Ok(aisha) =
    list.find(data_platform.lanes, fn(lane) { lane.engineer_id == 3 })
  let assert [first_week, second_week, ..] = aisha.cells
  assert first_week == shared_schedule.OnLeave
  assert second_week
    == shared_schedule.Working(fraction: 1.0, over_allocated: False)
}

pub fn capability_gaps_use_the_rollup_qualifying_rule_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(ledger) =
    list.find(schedule.projects, fn(project) { project.project_id == 100 })
  let assert Ok(shared_schedule.RequirementLine(gaps: payments_gaps, ..)) =
    list.find(ledger.lines, fn(line) {
      case line.kind {
        shared_schedule.CapabilityLine(capability_id: 1, ..) -> True
        _ -> False
      }
    })
  assert payments_gaps == list.repeat(1.5, 12)
}

pub fn level_gaps_open_when_the_requirement_window_starts_test() {
  let assert Ok(schedule) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(edge) =
    list.find(schedule.projects, fn(project) { project.project_id == 500 })
  let assert Ok(shared_schedule.RequirementLine(gaps: level_three_gaps, ..)) =
    list.find(edge.lines, fn(line) {
      line.kind == shared_schedule.LevelLine(level: 3)
    })
  assert level_three_gaps
    == list.append(list.repeat(0.0, 7), list.repeat(2.0, 5))
  assert edge.team
    == [
      shared_schedule.OpenSeat(level: 3, fraction: 1.0),
      shared_schedule.OpenSeat(level: 3, fraction: 1.0),
      shared_schedule.OpenSeat(level: 4, fraction: 1.0),
      shared_schedule.OpenSeat(level: 5, fraction: 0.5),
    ]
  assert edge.annotation == None
}
```

(Priya covers Payments Platform at rollup 3.5556 ≥ 3 with fraction 0.5 → gap 2.0 − 0.5 = 1.5 all 12 weeks. Edge Analytics' requirements start 2026-08-01: the first covered week column is Aug 03 — weeks Jun 15..Jul 27 are 7 columns of 0.0, Aug 03..Aug 31 are 5 columns of 2.0.)

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t4.log 2>&1; tail -5 /tmp/t4.log`
Expected: FAIL — module `tempo/server/schedule/view` does not exist.

- [x] **Step 2: Write the six SQL queries, regenerate squirrel**

`server/src/tempo/server/schedule/sql/schedule_weeks.sql` (the series every other query re-derives internally; `timeline` reads it once for the payload's week header):

```sql
-- schedule_weeks.sql — the 12 week-start Mondays opening at the Monday of $1.
-- $1 = as_of.
SELECT week_start::date AS week
FROM generate_series(
  date_trunc('week', $1::date),
  date_trunc('week', $1::date) + interval '11 weeks',
  interval '1 week') AS week_start
ORDER BY week;
```

`server/src/tempo/server/schedule/sql/schedule_projects.sql`:

```sql
-- schedule_projects.sql — projects whose run overlaps the 12-week window opening
-- at the Monday of $1. Runs are bounded (contained in bounded contract terms),
-- so upper() is safe. $1 = as_of.
SELECT
  project_run.project_id,
  coalesce(project_current.title, '') AS title,
  coalesce(client_current.name, '') AS client,
  lower(project_run.active_during) AS run_from,
  upper(project_run.active_during) AS run_to
FROM project_run
JOIN contract_terms
  ON contract_terms.contract_id = project_run.contract_id
 AND contract_terms.term @> lower(project_run.active_during)
JOIN client_current ON client_current.id = contract_terms.client_id
JOIN project_current ON project_current.id = project_run.project_id
WHERE project_run.active_during
   && daterange(date_trunc('week', $1::date)::date,
                (date_trunc('week', $1::date) + interval '12 weeks')::date, '[)')
ORDER BY title;
```

`schedule_lanes.sql`:

```sql
-- schedule_lanes.sql — one row per allocated engineer x week for every project in
-- the window: the fraction in force at the week start and whether leave covers it.
-- Lane level is as-of $1 (the label), coalesced to 0 when no role row covers it.
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  allocation.project_id,
  allocation.engineer_id,
  coalesce(engineer_current.name, '') AS name,
  coalesce(role_now.level, 0) AS level,
  weeks.week,
  allocation.fraction AS fraction,
  (leave.engineer_id IS NOT NULL) AS on_leave
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
JOIN engineer_current ON engineer_current.id = allocation.engineer_id
LEFT JOIN engineer_role role_now
  ON role_now.engineer_id = allocation.engineer_id
 AND role_now.held_during @> $1::date
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
ORDER BY allocation.project_id, name, weeks.week;
```

`schedule_totals.sql`:

```sql
-- schedule_totals.sql — each engineer's total allocated fraction per week across
-- ALL projects, for the over-allocation flag (> 1.0). $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT allocation.engineer_id, weeks.week, sum(allocation.fraction) AS total
FROM weeks
JOIN allocation ON allocation.allocated_during @> weeks.week
GROUP BY allocation.engineer_id, weeks.week
ORDER BY allocation.engineer_id, weeks.week;
```

`schedule_level_gaps.sql`:

```sql
-- schedule_level_gaps.sql — level requirement lines per project per week with the
-- covered sum (allocated fractions of engineers at level >= required, off leave).
-- Gap arithmetic happens in the view: gap = greatest(0, quantity - covered).
-- $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
)
SELECT
  requirement.project_id,
  requirement.level,
  weeks.week,
  requirement.quantity AS quantity,
  coalesce(
    sum(allocation.fraction)
      FILTER (WHERE role_week.level >= requirement.level
                AND leave.engineer_id IS NULL),
    0) AS covered
FROM weeks
JOIN project_requirement requirement ON requirement.required_during @> weeks.week
LEFT JOIN allocation
  ON allocation.project_id = requirement.project_id
 AND allocation.allocated_during @> weeks.week
LEFT JOIN engineer_role role_week
  ON role_week.engineer_id = allocation.engineer_id
 AND role_week.held_during @> weeks.week
LEFT JOIN leave
  ON leave.engineer_id = allocation.engineer_id
 AND leave.on_leave_during @> weeks.week
GROUP BY requirement.project_id, requirement.level, weeks.week, requirement.quantity
ORDER BY requirement.project_id, requirement.level, weeks.week;
```

`schedule_capability_gaps.sql`:

```sql
-- schedule_capability_gaps.sql — capability requirement lines per project per week:
-- covered = sum of allocated fractions of engineers whose weighted-average rollup
-- (unassessed skills count 0) meets the target level that week and who are off
-- leave; best = the highest qualifying-or-not rollup on the team that week, for
-- the inspector's coverage chart. $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
),
demand AS (
  SELECT project_capability.project_id, project_capability.capability_id,
         project_capability.target_level, project_capability.quantity, weeks.week
  FROM weeks
  JOIN project_capability ON project_capability.required_during @> weeks.week
),
staff AS (
  SELECT demand.project_id, demand.capability_id, demand.target_level, demand.week,
         allocation.engineer_id, allocation.fraction,
         (leave.engineer_id IS NOT NULL) AS on_leave
  FROM demand
  JOIN allocation
    ON allocation.project_id = demand.project_id
   AND allocation.allocated_during @> demand.week
  LEFT JOIN leave
    ON leave.engineer_id = allocation.engineer_id
   AND leave.on_leave_during @> demand.week
),
proficiency AS (
  SELECT staff.project_id, staff.capability_id, staff.target_level, staff.week,
         staff.engineer_id, staff.fraction, staff.on_leave,
         (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
           / sum(capability_skill.weight)::numeric) AS rollup
  FROM staff
  JOIN capability_skill
    ON capability_skill.capability_id = staff.capability_id
   AND capability_skill.mapped_during @> staff.week
  LEFT JOIN engineer_skill
    ON engineer_skill.skill_id = capability_skill.skill_id
   AND engineer_skill.engineer_id = staff.engineer_id
   AND engineer_skill.assessed_during @> staff.week
  GROUP BY staff.project_id, staff.capability_id, staff.target_level, staff.week,
           staff.engineer_id, staff.fraction, staff.on_leave
)
SELECT
  demand.project_id,
  demand.capability_id,
  coalesce(capability_profile.name, '') AS name,
  demand.target_level,
  demand.week,
  demand.quantity AS quantity,
  coalesce(
    sum(proficiency.fraction)
      FILTER (WHERE proficiency.rollup >= demand.target_level
                AND NOT proficiency.on_leave),
    0) AS covered,
  coalesce(max(proficiency.rollup), 0) AS best
FROM demand
JOIN capability_profile
  ON capability_profile.capability_id = demand.capability_id
 AND capability_profile.defined_during @> demand.week
LEFT JOIN proficiency
  ON proficiency.project_id = demand.project_id
 AND proficiency.capability_id = demand.capability_id
 AND proficiency.week = demand.week
GROUP BY demand.project_id, demand.capability_id, capability_profile.name,
         demand.target_level, demand.week, demand.quantity
ORDER BY demand.project_id, name, demand.week;
```

Run: `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo bin/squirrel > /tmp/squirrel.log 2>&1; tail -5 /tmp/squirrel.log`
Expected: `server/src/tempo/server/schedule/sql.gleam` generated with row types `ScheduleProjectsRow`, `ScheduleLanesRow`, `ScheduleTotalsRow`, `ScheduleLevelGapsRow`, `ScheduleCapabilityGapsRow` (fractions/quantities/covered/best decode as Float via `pog.numeric_decoder()`, weeks as `Date`, `on_leave` as Bool).

- [x] **Step 3: Implement the view assembly**

`server/src/tempo/server/schedule/view.gleam`:

```gleam
//// The schedule read model: assemble the weekly allocation timeline — lanes,
//// requirement gap lines, team seats, capability coverage — from five SQL
//// queries run on the CALLER's connection, so the preview executor can evaluate
//// the same read inside its transaction (reads on a tx connection stay serial;
//// the async fan-out helper is pool-only).

import gleam/dict.{type Dict}
import gleam/float
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/schedule/view.{
  type CellState, type EngineerLane, type ProjectSchedule, type RequirementLine,
  type Schedule, type Seat, CapabilityCoverage, CapabilityLine, EngineerLane,
  FilledSeat, Idle, LevelLine, OnLeave, OpenSeat, OutsideRun, ProjectSchedule,
  RequirementLine, Schedule, Working,
} as shared_schedule
import tempo/server/schedule/sql

pub fn timeline(
  db: pog.Connection,
  as_of: Date,
) -> Result(Schedule, pog.QueryError) {
  use weeks <- result.try(sql.schedule_weeks(db, as_of))
  use projects <- result.try(sql.schedule_projects(db, as_of))
  use lanes <- result.try(sql.schedule_lanes(db, as_of))
  use totals <- result.try(sql.schedule_totals(db, as_of))
  use level_gaps <- result.try(sql.schedule_level_gaps(db, as_of))
  use capability_gaps <- result.map(sql.schedule_capability_gaps(db, as_of))
  assemble(
    as_of,
    list.map(weeks.rows, fn(row) { row.week }),
    projects.rows,
    lanes.rows,
    totals.rows,
    level_gaps.rows,
    capability_gaps.rows,
  )
}
```

`timeline` runs `sql.schedule_weeks(db, as_of)` first and threads `weeks: List(Date)` (12 Mondays, in order) through `assemble` — every per-week list in the payload is built by mapping over these weeks, so missing rows become the dense default (`Idle`, gap `0.0`). `assemble` builds the payload with plain list/dict passes — the full logic:

1. Per project (preserving `schedule_projects` order):
   - **Lanes**: group lane rows by `engineer_id`; lane label = the row's `name`/`level`. Cells = for each week in order: if week `< run_from` or `>= run_to` → `OutsideRun`; else if a lane row exists for that week → `OnLeave` when `on_leave`, otherwise `Working(fraction:, over_allocated: total_for(engineer, week) >. 1.0)` using a `Dict(#(Int, Date), Float)` built from totals; else `Idle`. Date comparisons use a helper `fn before(a: Date, b: Date) -> Bool` via `calendar.naive_date_compare` — check `gleam/time/calendar` for the exact comparison fn name (the codebase already compares dates somewhere; `grep -rn "date_compare" server/src` and reuse that helper's idiom).
   - **Lines**: level lines from `schedule_level_gaps` grouped by `(project_id, level)`; per week present in rows, `gap = float.max(0.0, quantity -. covered)`; weeks missing from the rows (requirement not in force) get gap `0.0`. Keep only lines where `list.any(gaps, fn(g) { g >. 0.0 })`. Same for capability lines grouped by `(project_id, capability_id)` with kind `CapabilityLine(capability_id:, name:, target_level:)`.
   - **Team seats**: for each level requirement of the project (distinct `(level, quantity)` at the FIRST week the line is in force): qualifying lanes = lanes with `lane.level >= level`, sorted by fraction descending then name; each becomes `FilledSeat(level:, engineer_id:, name:, fraction:)` consuming its fraction from the quantity; `remaining = quantity -. sum(fractions)`; while `remaining >. 0.0`: emit `OpenSeat(level:, fraction: float.min(1.0, remaining))` and subtract. A lane already seated by a lower-level line still seats here (independent sums — same rule as gaps).
   - **Capabilities**: one `CapabilityCoverage` per capability line: `team_proficiency = max over weeks of the row's best` (0.0 when never staffed).
   - `annotation: None` (the executor sets it in Task 6).

Implement `assemble` fully now (it is ~150 lines of grouping code; keep each grouping in its own private fn: `lanes_for`, `lines_for`, `seats_for`, `coverage_for`).

- [x] **Step 4: HTTP handler + route**

`server/src/tempo/server/schedule/http.gleam` (mirror `board/http.gleam` exactly):

```gleam
import gleam/http
import tempo/server/context.{type Context}
import tempo/server/schedule/view as schedule
import tempo/server/web/request
import tempo/server/web/response
import shared/schedule/view as shared_schedule
import wisp

pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case schedule.timeline(ctx.db, as_of) {
        Ok(timeline) ->
          response.json_response(shared_schedule.encode_schedule(timeline))
        Error(error) -> response.db_error_response(error)
      }
  }
}
```

Router (`server/src/tempo/server/web/router.gleam`), beside the `["api", "board"]` arm:

```gleam
    ["api", "schedule"] -> {
      use _principal <- guard.require(context, access.read_projects)
      schedule_http.handle(request, context)
    }
```

with `import tempo/server/schedule/http as schedule_http`.

- [x] **Step 5: Run tests**

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t4.log 2>&1; tail -10 /tmp/t4.log`
Expected: PASS — all five schedule tests green. If a gap assertion differs, print the actual rows by asserting against a deliberately wrong value once, read the diff, and fix the QUERY (never bend the expected value to a wrong actual — the arithmetic in the test comments is the spec).

- [x] **Step 6: Commit**

```bash
git add server/src/tempo/server/schedule server/test/schedule_test.gleam server/src/tempo/server/web/router.gleam
git commit -m "Add schedule read model: 12-week timeline with gap lines and seats

generate_series week buckets; lanes with leave and cross-project
over-allocation; level and capability gap lines (independent sums,
rollup-qualified); team seats with open remainders; GET /api/schedule."
```

---

### Task 5: Candidates read

**Files:**
- Create: `server/src/tempo/server/schedule/sql/schedule_candidates.sql`
- Modify: `server/src/tempo/server/schedule/sql.gleam` (regen), `server/src/tempo/server/schedule/view.gleam`, `server/src/tempo/server/schedule/http.gleam`, `server/src/tempo/server/web/router.gleam`
- Test: `server/test/schedule_test.gleam`

**Interfaces:**
- Produces: `schedule_view.candidates(db, as_of: Date, project_id: Int, level: Int, from: Date, to: Date) -> Result(List(shared_schedule.Candidate), pog.QueryError)`; `GET /api/schedule/candidates?as_of=&project=&level=&from=&to=`.

- [x] **Step 1: Failing test**

Append to `server/test/schedule_test.gleam`:

```gleam
pub fn candidates_list_every_qualifier_with_free_fraction_test() {
  let assert Ok(candidates) =
    schedule_view.candidates(
      test_pool.db(),
      Date(2026, calendar.June, 15),
      500,
      3,
      Date(2026, calendar.August, 1),
      Date(2027, calendar.January, 1),
    )
  let names =
    list.map(candidates, fn(candidate) {
      #(candidate.name, candidate.level, candidate.free)
    })
  assert names
    == [
      #("Aisha Okafor", 6, 0.0),
      #("Priya Sharma", 5, 0.0),
      #("Marcus Chen", 4, 0.0),
    ]
}
```

(All three engineers hold level ≥ 3 as-of 2026-06-15 and are fully committed over the window → free 0.0; committed engineers are deliberately included. Order: level desc, then name.)

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t5.log 2>&1; tail -5 /tmp/t5.log` — FAIL: `candidates` undefined.

- [x] **Step 2: SQL + regen**

`server/src/tempo/server/schedule/sql/schedule_candidates.sql`:

```sql
-- schedule_candidates.sql — every employed engineer qualifying for a level seat
-- (role level >= $3 as-of $1), with their worst-week free fraction over the
-- seat's window [$4, $5) (can go negative; the view floors it), a commitment
-- summary, and their best rollup among the project's required capabilities
-- (0 when the project has none). Fully committed engineers are included by
-- design — nominating one over-allocates, which the preview flags.
-- $1 = as_of, $2 = project_id, $3 = level, $4 = from, $5 = to.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $4::date),
    date_trunc('week', ($5::date - 1)::timestamp),
    interval '1 week') AS week_start
),
qualifier AS (
  SELECT employment.engineer_id,
         coalesce(engineer_current.name, '') AS name,
         engineer_role.level
  FROM employment
  JOIN engineer_role
    ON engineer_role.engineer_id = employment.engineer_id
   AND engineer_role.held_during @> $1::date
   AND engineer_role.level >= $3
  JOIN engineer_current ON engineer_current.id = employment.engineer_id
  WHERE employment.employed_during @> $1::date
),
load AS (
  SELECT qualifier.engineer_id, weeks.week,
         coalesce(sum(allocation.fraction), 0) AS total
  FROM qualifier
  CROSS JOIN weeks
  LEFT JOIN allocation
    ON allocation.engineer_id = qualifier.engineer_id
   AND allocation.allocated_during @> weeks.week
  GROUP BY qualifier.engineer_id, weeks.week
),
commitment AS (
  SELECT qualifier.engineer_id,
         coalesce(
           string_agg(DISTINCT coalesce(project_current.title, ''), ', '
                      ORDER BY coalesce(project_current.title, '')),
           '') AS commitments
  FROM qualifier
  LEFT JOIN allocation
    ON allocation.engineer_id = qualifier.engineer_id
   AND allocation.allocated_during && daterange($4::date, $5::date, '[)')
  LEFT JOIN project_current ON project_current.id = allocation.project_id
  GROUP BY qualifier.engineer_id
),
required_capability AS (
  SELECT DISTINCT project_capability.capability_id
  FROM project_capability
  WHERE project_capability.project_id = $2
    AND project_capability.required_during && daterange($4::date, $5::date, '[)')
),
rollup AS (
  SELECT qualifier.engineer_id,
         max(per_capability.rollup) AS proficiency
  FROM qualifier
  JOIN required_capability ON true
  JOIN LATERAL (
    SELECT (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
             / sum(capability_skill.weight)::numeric) AS rollup
    FROM capability_skill
    LEFT JOIN engineer_skill
      ON engineer_skill.skill_id = capability_skill.skill_id
     AND engineer_skill.engineer_id = qualifier.engineer_id
     AND engineer_skill.assessed_during @> $1::date
    WHERE capability_skill.capability_id = required_capability.capability_id
      AND capability_skill.mapped_during @> $1::date
  ) AS per_capability ON true
  GROUP BY qualifier.engineer_id
)
SELECT qualifier.engineer_id, qualifier.name, qualifier.level,
       coalesce(rollup.proficiency, 0) AS proficiency,
       (1 - max(load.total)) AS free,
       commitment.commitments
FROM qualifier
JOIN load ON load.engineer_id = qualifier.engineer_id
JOIN commitment ON commitment.engineer_id = qualifier.engineer_id
LEFT JOIN rollup ON rollup.engineer_id = qualifier.engineer_id
GROUP BY qualifier.engineer_id, qualifier.name, qualifier.level,
         rollup.proficiency, commitment.commitments
ORDER BY qualifier.level DESC, qualifier.name;
```

Regen: `DATABASE_URL=postgres://tempo:tempo@127.0.0.1:5435/tempo bin/squirrel > /tmp/squirrel.log 2>&1; tail -5 /tmp/squirrel.log`.

- [x] **Step 3: View fn + endpoint**

In `schedule/view.gleam`:

```gleam
pub fn candidates(
  db: pog.Connection,
  as_of: Date,
  project_id: Int,
  level: Int,
  from: Date,
  to: Date,
) -> Result(List(shared_schedule.Candidate), pog.QueryError) {
  use returned <- result.map(sql.schedule_candidates(
    db, as_of, project_id, level, from, to,
  ))
  list.map(returned.rows, fn(row) {
    shared_schedule.Candidate(
      engineer_id: row.engineer_id,
      name: row.name,
      level: row.level,
      proficiency: row.proficiency,
      free: float.max(0.0, row.free),
      commitments: row.commitments,
    )
  })
}
```

(If squirrel orders the generated fn's args differently, match the generated signature.) In `schedule/http.gleam` add:

```gleam
pub fn handle_candidates(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let params = {
    use as_of <- result.try(request.date_from_query(req, "as_of"))
    use project <- result.try(request.int_from_query(req, "project"))
    use level <- result.try(request.int_from_query(req, "level"))
    use from <- result.try(request.date_from_query(req, "from"))
    use to <- result.map(request.date_from_query(req, "to"))
    #(as_of, project, level, from, to)
  }
  case params {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(as_of, project, level, from, to)) ->
      case schedule.candidates(ctx.db, as_of, project, level, from, to) {
        Ok(candidates) ->
          response.json_response(
            json.array(candidates, shared_schedule.encode_candidate),
          )
        Error(error) -> response.db_error_response(error)
      }
  }
}
```

(If `web/request.gleam` has no `int_from_query`, add one mirroring `date_from_query` — same `Result(Int, String)` style via `int.parse`.) Router:

```gleam
    ["api", "schedule", "candidates"] -> {
      use _principal <- guard.require(context, access.read_projects)
      schedule_http.handle_candidates(request, context)
    }
```

This arm must precede any `["api", "schedule"]` wildcard matching — Gleam cases match in order; place the longer path first.

- [x] **Step 4: Run, commit**

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t5.log 2>&1; tail -5 /tmp/t5.log` — PASS.

```bash
git add server/src/tempo/server/schedule server/src/tempo/server/web/router.gleam server/src/tempo/server/web/request.gleam server/test/schedule_test.gleam
git commit -m "Add seat-candidates read: qualifiers with free fraction and rollup

Level-qualified employed engineers over a seat window, worst-week free
fraction (floored at 0), commitment summary, best rollup among the
project's required capabilities; committed engineers included so
nomination can deliberately over-allocate."
```

---

### Task 6: Preview/apply executor + POST endpoints

**Files:**
- Create: `server/src/tempo/server/schedule/executor.gleam`
- Modify: `server/src/tempo/server/operation.gleam` (add `describe`), `server/src/tempo/server/schedule/http.gleam`, `server/src/tempo/server/web/router.gleam`
- Test: `server/test/schedule_executor_test.gleam`

**Interfaces:**
- Consumes: `command.dispatch_in`, `auth.authorize`, `schedule_view.timeline`.
- Produces:

```gleam
pub fn preview_in(conn: pog.Connection, actor: String, as_of: Date, commands: List(Command)) -> Result(PreviewResult, OperationError)
pub fn preview(ctx: Context, principal: Principal, as_of: Date, commands: List(Command)) -> Result(PreviewResult, OperationError)
pub fn apply(ctx: Context, principal: Principal, as_of: Date, commands: List(Command)) -> Result(PreviewResult, OperationError)
pub fn operation.describe(error: OperationError) -> String
```

`POST /api/schedule/preview` and `POST /api/schedule/apply`, body `{"as_of": "2026-06-15", "operations": [<command json>...]}`.

- [x] **Step 1: Failing tests**

`server/test/schedule_executor_test.gleam` (same `rolling_back` harness as Task 2; import `shared/allocation/command as allocation_command`, `shared/schedule/view as shared_schedule`, `tempo/server/schedule/executor`, `tempo/server/schedule/view as schedule_view`):

```gleam
fn assign(engineer_id: Int, project_id: Int, fraction: Float) -> gateway.Command {
  gateway.AllocationCommand(allocation_command.AssignToProject(
    engineer_id:,
    project_id:,
    fraction:,
    valid_from: Date(2026, calendar.August, 1),
    valid_to: Date(2027, calendar.January, 1),
  ))
}

pub fn preview_leaves_the_database_unchanged_test() {
  let assert Ok(before) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  let assert Ok(previewed) =
    executor.preview(
      test_pool.ctx(),
      test_pool.admin_principal(),
      Date(2026, calendar.June, 15),
      [assign(3, 500, 0.5)],
    )
  let assert Ok(after) =
    schedule_view.timeline(test_pool.db(), Date(2026, calendar.June, 15))
  assert previewed.outcomes == [shared_schedule.OperationApplied]
  assert after == before
  assert previewed.schedule != before
}

pub fn a_rejected_op_rolls_back_to_its_savepoint_and_the_rest_evaluate_test() {
  let assert Ok(previewed) =
    executor.preview(
      test_pool.ctx(),
      test_pool.admin_principal(),
      Date(2026, calendar.June, 15),
      [
        gateway.EngagementCommand(engagement_command.RescheduleProject(
          project_id: 500,
          valid_from: Date(2026, calendar.May, 1),
          valid_to: Date(2026, calendar.August, 1),
        )),
        assign(3, 500, 0.5),
      ],
    )
  let assert [shared_schedule.OperationRejected(..), shared_schedule.OperationApplied] =
    previewed.outcomes
  let assert Ok(edge) =
    list.find(previewed.schedule.projects, fn(project) {
      project.project_id == 500
    })
  let assert option.Some(_) = edge.annotation
  let assert Ok(aisha_lane) =
    list.find(edge.lanes, fn(lane) { lane.engineer_id == 3 })
  let assert Ok(week_of_aug_3) = aisha_lane.cells |> list.drop(7) |> list.first
  assert week_of_aug_3
    == shared_schedule.Working(fraction: 0.5, over_allocated: True)
}

pub fn apply_commits_and_is_all_or_nothing_test() {
  let outcome =
    rolling_back(fn(conn) {
      let bad_then_good = [
        gateway.EngagementCommand(engagement_command.RescheduleProject(
          project_id: 100,
          valid_from: Date(2024, calendar.February, 1),
          valid_to: Date(2027, calendar.January, 1),
        )),
        assign(3, 500, 0.5),
      ]
      executor.apply_in(
        conn,
        "tester",
        Date(2026, calendar.June, 15),
        bad_then_good,
      )
    })
  assert outcome == Error(operation.ProjectPinned)
}

pub fn preview_refuses_an_unauthorized_operation_test() {
  let outcome =
    executor.preview(
      test_pool.ctx(),
      test_pool.engineer_principal(),
      Date(2026, calendar.June, 15),
      [assign(3, 500, 0.5)],
    )
  let assert Error(operation.Unauthorized(..)) = outcome
}
```

Notes for the implementer:
- `test_pool` may not expose `ctx()`/`admin_principal()`/`engineer_principal()` under those names — read `server/test/test_pool.gleam` and the board test's `test_pool.ctx()` usage, plus how `server/test/auth_test.gleam` or `operations_test.gleam` builds a `Principal` for an owner/manager and for a plain engineer, and use those exact constructors. The intent is fixed: one principal that holds `allocation.manage` + `engagement.manage`, one that holds neither.
- Aisha (engineer 3) is on project 300 at 1.0; assigning her 0.5 on 500 makes her week total 1.5 → `over_allocated: True` from Aug 03 (index 7).
- The preview test uses the POOL (`executor.preview` opens its own transaction and rolls back); the apply test drives the tx-free `apply_in` inside the test's own rolled-back transaction so nothing commits to the shared test DB.

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/t6.log 2>&1; tail -5 /tmp/t6.log` — FAIL: `executor` module missing.

- [x] **Step 2: Add `operation.describe`**

In `server/src/tempo/server/operation.gleam`:

```gleam
/// One user-facing sentence per rejection, for preview outcome rows.
pub fn describe(error: OperationError) -> String {
  case error {
    ContainmentViolated -> "outside the containing period (contract, run, or employment)"
    OverlappingFact -> "overlaps an existing fact"
    ProjectPinned -> "the project has logged time or invoices"
    NoSuchVersion -> "no covering version exists at that date"
    ...
  }
}
```

Write an arm for EVERY variant — the compiler enumerates them; phrase each as a short lowercase clause. `Unauthorized(actor:, command:)` → `"not permitted"`. `DatabaseError(_)` → `"database error"`.

- [x] **Step 3: Implement the executor**

`server/src/tempo/server/schedule/executor.gleam`:

```gleam
//// Preview/apply a scenario: run a batch of commands through the ordinary
//// dispatch_in seam inside ONE transaction, evaluate the timeline on the same
//// connection, then roll back (preview) or commit (apply). Preview wraps each
//// command in a savepoint so a rejected draft reports its outcome and the rest
//// still evaluate; apply is all-or-nothing.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/allocation/command as allocation_command
import shared/command.{type Command, AllocationCommand, EngagementCommand}
import shared/engagement/command as engagement_command
import shared/schedule/view.{
  type PreviewResult, OperationApplied, OperationRejected, PreviewResult,
} as shared_schedule
import tempo/server/auth.{type Principal}
import tempo/server/command as dispatch
import tempo/server/context.{type Context}
import tempo/server/operation.{type OperationError}
import tempo/server/schedule/view as schedule_view

type Rolled {
  Evaluated(PreviewResult)
  Failed(OperationError)
}

pub fn preview(
  ctx: Context,
  principal: Principal,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use actor <- result.try(authorize_all(principal, commands))
  case
    pog.transaction(ctx.db, fn(conn) {
      Error(case preview_in(conn, actor, as_of, commands) {
        Ok(previewed) -> Evaluated(previewed)
        Error(error) -> Failed(error)
      })
    })
  {
    Error(pog.TransactionRolledBack(Evaluated(previewed))) -> Ok(previewed)
    Error(pog.TransactionRolledBack(Failed(error))) -> Error(error)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
    Ok(_) -> panic as "preview always rolls back"
  }
}

pub fn apply(
  ctx: Context,
  principal: Principal,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use actor <- result.try(authorize_all(principal, commands))
  case
    pog.transaction(ctx.db, fn(conn) { apply_in(conn, actor, as_of, commands) })
  {
    Ok(applied) -> Ok(applied)
    Error(pog.TransactionRolledBack(error)) -> Error(error)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
  }
}

pub fn preview_in(
  conn: pog.Connection,
  actor: String,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use outcomes <- result.try(
    commands
    |> list.index_map(fn(command, index) { #(index, command) })
    |> list.try_map(fn(indexed) {
      let #(index, command) = indexed
      let savepoint = "scenario_op_" <> int.to_string(index)
      use _ <- result.try(run_sql(conn, "SAVEPOINT " <> savepoint))
      case dispatch.dispatch_in(conn, actor, command) {
        Ok(_event) -> {
          use _ <- result.map(run_sql(conn, "RELEASE SAVEPOINT " <> savepoint))
          #(command, OperationApplied)
        }
        Error(error) -> {
          use _ <- result.map(run_sql(
            conn,
            "ROLLBACK TO SAVEPOINT " <> savepoint,
          ))
          #(command, OperationRejected(detail: operation.describe(error)))
        }
      }
    }),
  )
  use timeline <- result.map(
    schedule_view.timeline(conn, as_of)
    |> result.map_error(operation.classify),
  )
  PreviewResult(
    schedule: annotate(timeline, outcomes),
    outcomes: list.map(outcomes, fn(pair) { pair.1 }),
  )
}

pub fn apply_in(
  conn: pog.Connection,
  actor: String,
  as_of: Date,
  commands: List(Command),
) -> Result(PreviewResult, OperationError) {
  use _ <- result.try(
    list.try_map(commands, fn(command) {
      dispatch.dispatch_in(conn, actor, command)
    }),
  )
  use timeline <- result.map(
    schedule_view.timeline(conn, as_of)
    |> result.map_error(operation.classify),
  )
  PreviewResult(
    schedule: timeline,
    outcomes: list.map(commands, fn(_) { OperationApplied }),
  )
}

fn authorize_all(
  principal: Principal,
  commands: List(Command),
) -> Result(String, OperationError) {
  list.try_fold(commands, "", fn(_actor, command) {
    case auth.authorize(principal, command) {
      Ok(actor) -> Ok(actor)
      Error(auth.Forbidden(actor:, command:)) ->
        Error(operation.Unauthorized(actor:, command:))
    }
  })
}

fn run_sql(
  conn: pog.Connection,
  sql: String,
) -> Result(Nil, OperationError) {
  pog.query(sql)
  |> pog.execute(conn)
  |> result.replace(Nil)
  |> result.map_error(operation.classify)
}

fn annotate(
  timeline: shared_schedule.Schedule,
  outcomes: List(#(Command, shared_schedule.OperationOutcome)),
) -> shared_schedule.Schedule {
  let rejected_projects =
    list.filter_map(outcomes, fn(pair) {
      case pair {
        #(command, OperationRejected(detail:)) ->
          case command_project(command) {
            Some(project_id) -> Ok(#(project_id, detail))
            None -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  shared_schedule.Schedule(
    ..timeline,
    projects: list.map(timeline.projects, fn(project) {
      case list.key_find(rejected_projects, project.project_id) {
        Ok(detail) ->
          shared_schedule.ProjectSchedule(..project, annotation: Some(detail))
        Error(Nil) -> project
      }
    }),
  )
}

fn command_project(command: Command) -> option.Option(Int) {
  case command {
    EngagementCommand(engagement_command.RescheduleProject(project_id:, ..)) ->
      Some(project_id)
    AllocationCommand(allocation_command.AssignToProject(project_id:, ..)) ->
      Some(project_id)
    AllocationCommand(allocation_command.ChangeAllocationFraction(
      project_id:,
      ..,
    )) -> Some(project_id)
    AllocationCommand(allocation_command.RollOff(project_id:, ..)) ->
      Some(project_id)
    _ -> None
  }
}
```

(Check `auth.gleam` for the exact `authorize`/`Forbidden` shapes — Task 2's `command.gleam` reading shows `auth.authorize(principal, command)` → `Ok(actor)` / `Error(Forbidden(actor:, command:))`. If pog's `execute` on a `Query(Nil)` needs no `returning`, the `run_sql` above is exact.)

- [x] **Step 4: HTTP endpoints**

In `schedule/http.gleam` add a body decoder + two handlers (mirror `web/operations.gleam`'s body-reading and error mapping — reuse its exported helpers if any; otherwise copy its `wisp.require_json` + decode idiom):

```gleam
fn scenario_decoder() -> decode.Decoder(#(Date, List(command.Command))) {
  use as_of <- decode.field("as_of", wire.date_decoder())
  use operations <- decode.field(
    "operations",
    decode.list(command.grouped_command_decoder()),
  )
  decode.success(#(as_of, operations))
}

pub fn handle_preview(req: wisp.Request, ctx: Context) -> wisp.Response {
  scenario_endpoint(req, ctx, executor.preview)
}

pub fn handle_apply(req: wisp.Request, ctx: Context) -> wisp.Response {
  scenario_endpoint(req, ctx, executor.apply)
}

fn scenario_endpoint(
  req: wisp.Request,
  ctx: Context,
  run: fn(Context, auth.Principal, Date, List(command.Command)) ->
    Result(shared_schedule.PreviewResult, operation.OperationError),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use principal <- guard.require_principal(req, ctx)
  use json_body <- wisp.require_json(req)
  case decode.run(json_body, scenario_decoder()) {
    Error(_) -> wisp.bad_request("expected {as_of, operations}")
    Ok(#(as_of, operations)) ->
      case run(ctx, principal, as_of, operations) {
        Ok(result) ->
          response.json_response(shared_schedule.encode_preview_result(result))
        Error(error) -> operations.error_response(error)
      }
  }
}
```

Adaptation notes (read the real modules, keep the intent): how a handler obtains the `Principal` (`guard.require_principal` is illustrative — use whatever `web/operations.gleam` actually does to get the session principal); `command.grouped_command_decoder()`'s real name/signature in `shared/command.gleam`; `operations.error_response` is private — either export it from `web/operations.gleam` (rename-free `pub fn`) or add a small public `operation_error_response` there and call it from both sites. Router:

```gleam
    ["api", "schedule", "preview"] -> schedule_http.handle_preview(request, context)
    ["api", "schedule", "apply"] -> schedule_http.handle_apply(request, context)
```

(No route-level permission guard — authorization is per-operation inside the executor, exactly like `POST /api/operations`.)

- [x] **Step 5: Clean-build, run tests, commit**

Run: `cd server && gleam clean && TEMPO_DB_PORT=5435 ../bin/test > /tmp/t6.log 2>&1; tail -10 /tmp/t6.log`
Expected: PASS.

```bash
git add server/src/tempo/server/schedule server/src/tempo/server/operation.gleam server/src/tempo/server/web/operations.gleam server/src/tempo/server/web/router.gleam server/test/schedule_executor_test.gleam
git commit -m "Add scenario executor: preview via rollback, apply via commit

One transaction through dispatch_in; preview wraps each op in a
savepoint so rejections report typed outcomes and annotate the affected
project while the rest evaluate; apply is all-or-nothing; per-op
authorization up front; timeline evaluated on the tx connection."
```

---

### Task 7: Client — route, wiring, read-only timeline page

**Files:**
- Create: `client/src/client/page/schedule.gleam`, `client/styles/schedule.scss`
- Modify: `client/src/client/route.gleam`, `client/src/client/app.gleam`, `client/src/client/api.gleam`, `client/styles/main.scss`
- Verify: `bin/build`, `bin/test` (format + build gates)

**Interfaces:**
- Consumes: `shared/schedule/view` codecs; `api.get`; the frozen page interface `Model / Msg / init(route, as_of, actor) / update -> #(Model, Effect(Msg), List(page.OutMsg)) / view(model, as_of, permissions) / refetch(model, as_of, actor)`.
- Produces: route `/schedule`, sidebar entry "Schedule" (gated on `access.read_projects`), page rendering stats strip + per-project timeline grids; `api.post(url, body: Json, decoder, to_msg)` helper for Task 8.

- [x] **Step 1: Route + shell wiring**

`client/src/client/route.gleam`: add `Schedule` to the `Route` union, `["schedule"] -> Schedule` in `parse`, `Schedule -> "/schedule"` in `to_path`.

`client/src/client/app.gleam`: add the six mirror sites, copying the `Locations` twin exactly (Page union `SchedulePage(schedule.Model)`, Msg union `ScheduleMsg(schedule.Msg)`, `update` dispatch arm, `init_page` arm, `refetch_page` arm, `view_page` arm, `same_page` arm, sidebar `nav_link_if(permissions, perm.read_projects, active, as_of, route.Schedule, icons.board(), "Schedule")` — reuse an existing icon fn such as `icons.board()`; pick whichever existing icon reads closest to a calendar/timeline in `client/src/client/icons.gleam`).

- [x] **Step 2: `api.post` helper**

In `client/src/client/api.gleam`, alongside `get` (mirror its rsvp usage):

```gleam
pub fn post(
  url: String,
  body: Json,
  decoder: Decoder(a),
  to_msg: fn(Result(a, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(url, body, rsvp.expect_json(decoder, to_msg))
}
```

(Match `rsvp`'s real post signature — read how `submit_operation` posts and reuse its exact mechanics.)

- [x] **Step 3: The page module (read-only slice)**

`client/src/client/page/schedule.gleam` — full structure; scenario state lands in Task 8 but the Model already carries it:

```gleam
//// Schedule — the allocation timeline: every active project's engineer lanes
//// over 12 weekly columns with per-requirement gap rows, a portfolio stats
//// strip, and (Task 8) the project inspector + scenario preview/apply.

import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import client/api
import client/page.{type OutMsg}
import client/route.{type Route}
import client/time
import shared/command.{type Command}
import shared/schedule/view.{type Schedule} as schedule_view

pub type State {
  Loading
  Loaded(Schedule)
  Failed(detail: String)
}

pub type Model {
  Model(
    as_of: Date,
    actor: String,
    state: State,
    scenario: List(Command),
    preview_on: Bool,
    selected: Option(Int),
    preview_token: Int,
  )
}

pub type Msg {
  Fetched(as_of: Date, result: Result(Schedule, rsvp.Error(String)))
  ProjectSelected(project_id: Int)
}

pub fn init(_route: Route, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: Loading,
      scenario: [],
      preview_on: False,
      selected: None,
      preview_token: 0,
    ),
    fetch(as_of),
  )
}

pub fn refetch(model: Model, as_of: Date, actor: String) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, actor:), fetch(as_of))
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/schedule?as_of=" <> time.iso_date(as_of),
    schedule_view.schedule_decoder(),
    fn(result) { Fetched(as_of:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Fetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(schedule) -> Loaded(schedule)
            Error(error) -> Failed(api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }
    ProjectSelected(project_id:) ->
      #(Model(..model, selected: Some(project_id)), effect.none(), [])
  }
}

pub fn view(model: Model, _as_of: Date, permissions: Set(String)) -> Element(Msg) {
  let _ = permissions
  case model.state {
    Loading -> html.div([attribute.class("schedule schedule--loading")], [])
    Failed(detail:) ->
      html.div([attribute.class("schedule schedule--failed")], [html.text(detail)])
    Loaded(schedule) -> view_loaded(model, schedule)
  }
}
```

`view_loaded` renders (class names from the prototype, restated as token-only BEM under a `schedule-` prefix):

1. **Stats strip** `.schedule-stats`: three chips — requirement lines short (count of lines with any positive gap across projects), engineers over-allocated (distinct lanes containing a `Working(_, True)` cell), engineers on leave (distinct lanes containing an `OnLeave` cell) — each `.schedule-stats__stat` with a colored dot span; an actions group `.schedule-stats__actions` placeholder (Task 8 fills it).
2. **Per project** (`.schedule-project`, `.schedule-project--selected` when `model.selected == Some(project_id)`): a clickable header (`event.on_click(ProjectSelected(project_id))`) with title, client, run chip `time.iso_date(run_from) <> " → " <> time.iso_date(run_to)`, gap chips (one `.schedule-req` per line with any positive gap: label from `line_label`), and annotation pill when `annotation` is `Some(detail)`.
3. **Grid** `.schedule-grid` inside an `overflow-x` wrapper: a header row of the 12 week columns (`time.iso_date` shortened to `MMM DD` via a local `fn week_label(date: Date) -> String` using `calendar.month_to_string` prefix — keep it simple: 3-letter month + day int); one row per lane (sticky name cell: name + level chip) whose cells map `CellState` → cell element: `OutsideRun` → `·`, `Idle` → `–`, `OnLeave` → `leave`, `Working(fraction, over)` → `int.to_string(float.round(fraction *. 100.0))` with tint class `schedule-cell--f25/f50/f80/f100` by fraction band (≤0.25/≤0.5/≤0.8/else) and `schedule-cell--oa` when over; one gap row per line: cells `0` (`--g0`) or the gap formatted to one decimal (`--gap`).

`line_label(kind)`:

```gleam
fn line_label(kind: schedule_view.LineKind) -> String {
  case kind {
    schedule_view.LevelLine(level:) -> "L" <> int.to_string(level)
    schedule_view.CapabilityLine(name:, target_level:, ..) ->
      name <> " @L" <> int.to_string(target_level)
  }
}
```

- [x] **Step 4: Styles**

`client/styles/schedule.scss` — token-only (ADR-038): translate the prototype's semantics onto tempo tokens: fraction tints `color-mix(in srgb, var(--color-accent) 9|16|24|32%, var(--color-surface))`; gap cells `var(--color-danger-soft)`/`var(--color-danger)`; over-allocation ring `inset 0 0 0 var(--border-thin) var(--color-warn)`; leave `var(--color-leave-soft)`/`var(--color-leave)`; grid rows `display: grid; grid-template-columns: 14rem repeat(12, minmax(3.5rem, 1fr))`; sticky first column `position: sticky; left: 0; background: var(--color-surface)`; wrapper `overflow-x: auto`. Add `@use "schedule";` to `client/styles/main.scss` beside `locations`.

- [x] **Step 5: Build gates, visual check, commit**

Run: `bin/build > /tmp/build.log 2>&1; tail -3 /tmp/build.log` then `TEMPO_DB_PORT=5435 bin/test > /tmp/t7.log 2>&1; tail -5 /tmp/t7.log` (runs gleam format check + client build).
Expected: both green. Then `TEMPO_DB_PORT=5435 bin/serve` and eyeball `http://localhost:8000/schedule` signed in as admin@alembic.com.au: five project blocks, Edge Analytics shows L3/L4/L5 gap rows from Aug 03, Ledger Migration shows the two capability gap rows, Aisha's Jun 15 cell reads "leave".

```bash
git add client/src/client/page/schedule.gleam client/styles/schedule.scss client/src/client/route.gleam client/src/client/app.gleam client/src/client/api.gleam client/styles/main.scss
git commit -m "Add Schedule page: read-only 12-week allocation timeline

Stats strip, per-project grids with fraction-tinted lanes, leave and
over-allocation marks, gap rows for short requirement lines, project
selection state; /schedule route and sidebar entry."
```

---

### Task 8: Client — inspector, scenario, preview/apply

**Files:**
- Modify: `client/src/client/page/schedule.gleam`, `client/styles/schedule.scss`

**Interfaces:**
- Consumes: `api.post`, `shared_schedule.preview_result_decoder()`, `candidate_decoder()`, `policy`/`access` permission constants (`access.allocation_manage`, `access.engagement_manage`) for gating controls, `AssignToProject`/`ChangeAllocationFraction`/`RescheduleProject` command constructors.
- Produces: the complete interaction: select project → inspector (run dates, Team seats, Capabilities bars) → nominate from candidates → drafts accumulate → debounced preview re-render → Apply changes / clearing.

- [ ] **Step 1: Extend Model/Msg**

```gleam
pub type Inspector {
  Inspector(
    run_from: String,
    run_to: String,
    picker: Option(OpenPicker),
  )
}

pub type OpenPicker {
  OpenPicker(level: Int, fraction: Float, candidates: CandidateState)
}

pub type CandidateState {
  CandidatesLoading
  CandidatesLoaded(List(schedule_view.Candidate))
  CandidatesFailed(detail: String)
}
```

Add to `Model`: `inspector: Option(Inspector)`, `outcomes: List(schedule_view.OperationOutcome)`, `applying: Bool`. New `Msg` variants:

```gleam
  PreviewToggled
  RunDateEdited(which: RunBound, value: String)
  NominateOpened(level: Int, fraction: Float)
  CandidatesFetched(result: Result(List(schedule_view.Candidate), rsvp.Error(String)))
  CandidatePicked(candidate: schedule_view.Candidate)
  PickerClosed
  DraftRemoved(index: Int)
  PreviewSettled(token: Int)
  Previewed(token: Int, result: Result(schedule_view.PreviewResult, rsvp.Error(String)))
  ApplyRequested
  Applied(result: Result(schedule_view.PreviewResult, rsvp.Error(String)))
  ScenarioDiscarded

pub type RunBound {
  RunFrom
  RunTo
}
```

- [ ] **Step 2: Scenario mechanics in `update`**

- `ProjectSelected` now also seeds `inspector: Some(Inspector(run_from: time.iso_date(project.run_from), run_to: time.iso_date(project.run_to), picker: None))` from the loaded schedule.
- `NominateOpened(level:, fraction:)`: store the picker, fire `api.get("/api/schedule/candidates?as_of=" <> time.iso_date(model.as_of) <> "&project=" <> int.to_string(project_id) <> "&level=" <> int.to_string(level) <> "&from=" <> from <> "&to=" <> to, decode.list(schedule_view.candidate_decoder()), CandidatesFetched)` where `from`/`to` are the selected project's run bounds (ISO strings from the inspector) clamped: `from = max(as_of, run_from)` — compute by string comparison of ISO dates (lexicographic order is date order for ISO-8601; a one-line `fn max_iso(a, b)`).
- `CandidatePicked(candidate:)`: append `command.AllocationCommand(allocation_command.AssignToProject(engineer_id: candidate.engineer_id, project_id:, fraction: picker.fraction, valid_from: <from>, valid_to: <to>))` to `model.scenario` (parse the ISO strings back with the same date parsing `route.gleam`/`time.gleam` exposes — reuse `time`'s existing ISO parse; if only formatting exists, keep the picked window as `Date`s in `OpenPicker` instead of strings — prefer carrying `Date`s end-to-end and formatting only in `view`), close the picker, set `preview_on: True`, and schedule a preview (below).
- `RunDateEdited`: update the inspector strings; when both parse as dates and differ from the loaded run bounds, replace-or-append a `RescheduleProject(project_id, from, to)` draft for the selected project (at most one reschedule draft per project — `list.filter` out any prior one first), then schedule a preview.
- `DraftRemoved(index:)`: drop that scenario element, re-schedule preview (or plain refetch when the scenario empties).
- **Debounced preview** (rail-scrub pattern): every scenario change bumps `preview_token` and returns `scheduler.after(150, PreviewSettled(token))` (import `client/scheduler` — same module app.gleam uses). `PreviewSettled(token:)` fires the POST only when `token == model.preview_token`:

```gleam
fn preview_body(as_of: Date, scenario: List(Command)) -> json.Json {
  json.object([
    #("as_of", wire.encode_date(as_of)),
    #("operations", json.array(scenario, command.encode_command)),
  ])
}

fn preview(model: Model) -> Effect(Msg) {
  api.post(
    "/api/schedule/preview",
    preview_body(model.as_of, model.scenario),
    schedule_view.preview_result_decoder(),
    fn(result) { Previewed(token: model.preview_token, result:) },
  )
}
```

- `Previewed(token:, result:)`: ignore stale tokens; on Ok replace `state: Loaded(result.schedule)`, `outcomes: result.outcomes`; on Error set `Failed(api.describe_error(error))`.
- `PreviewToggled`: flip `preview_on`; when turning OFF, plain `fetch(model.as_of)` (shows live data; scenario is retained); when ON with a non-empty scenario, schedule a preview.
- `ApplyRequested`: `applying: True`, `api.post("/api/schedule/apply", preview_body(..), schedule_view.preview_result_decoder(), Applied)`.
- `Applied(result:)`: on Ok — clear `scenario`, `outcomes`, `applying`, keep `preview_on: False`, `fetch(model.as_of)`, emit `[page.OperationCommitted]`; on Error — `applying: False` and surface the error detail in the inspector (store in a `Model.apply_error: Option(String)` field shown beside the Apply button).
- `refetch` (as-of scrub): when the scenario is non-empty and `preview_on`, re-POST the preview at the new date instead of the plain GET.

- [ ] **Step 3: Inspector view**

Aside layout: wrap the Task 7 project column and a new aside in the existing `.detail-grid` convention (`components.scss`). The aside (`.schedule-inspector`) renders for `model.selected`:

- Header: title, client, "inspecting" tag.
- Run row: two `<input type="date">` bound to the inspector strings (`event.on_input(RunDateEdited(RunFrom, _))` etc.); when the selected project's `annotation` is `Some(detail)`, a `.schedule-inspector__error` line under the dates.
- **Team** section (`.schedule-seats`): one row per `Seat` of the selected project — `FilledSeat` → level chip + name + fraction; `OpenSeat` → dashed row, level chip + required fraction + a **Nominate** button (`NominateOpened(level, fraction)`), gated: render the button only when `set.contains(permissions, access.allocation_manage)`. Under an open seat with an open picker: the candidate list — each row a button (`CandidatePicked(candidate)`) with name + `"L" <> int.to_string(level)` + proficiency to one decimal + free percent, and a warn `▲` marker when `candidate.free == 0.0`.
- **Capabilities** section (`.schedule-caps`): per `CapabilityCoverage` a label row (name + `@L<target>`), and a bar: fill width `team_proficiency /. 7.0 *. 100.0`%, tick at `int.to_float(target_level) /. 7.0 *. 100.0`% — inline `attribute.style` for the two percentages only; colors by `team_proficiency >=. int.to_float(target_level)` (ok) else (danger).
- **Drafted seats**: while `preview_on` and the scenario contains an `AssignToProject` for the selected project, render that seat row with the accent "draft" treatment and a remove `✕` (`DraftRemoved(index)`).
- Stats-strip actions (from Task 7's placeholder): the Preview toggle (checkbox bound to `preview_on` → `PreviewToggled`) and `Apply changes` button (`ApplyRequested`, disabled when `model.scenario == []` or `model.applying`), gated on `access.allocation_manage`.

- [ ] **Step 4: Gates + visual check**

Run: `bin/build > /tmp/build.log 2>&1; tail -3 /tmp/build.log && TEMPO_DB_PORT=5435 bin/test > /tmp/t8.log 2>&1; tail -5 /tmp/t8.log`
Expected: green. Manual check on `bin/serve`: select Edge Analytics → four open seats → Nominate on an L3 seat → candidates listed (Aisha, Priya, Marcus, all 0% free with ▲) → pick Marcus → preview flips on, his lane appears with accent cells from Aug 03, the L3 gap row drops 2.0 → 1.5, his over-allocation ▲ shows (he's 1.0 on Data Platform); edit Edge Analytics' start date to 2026-05-01 → annotation pill "outside the containing period..." appears on the project header; Apply changes with only the nomination drafted → gap stays at 1.5 after reload.

- [ ] **Step 5: Commit**

```bash
git add client/src/client/page/schedule.gleam client/styles/schedule.scss
git commit -m "Add schedule inspector and scenario preview/apply

Seat rows with candidate nomination (committed engineers selectable,
flagged), run-date reschedule drafts, token-debounced preview through
the rollback endpoint, stats-strip preview toggle and batch apply."
```

---

### Task 9: e2e + full gates

**Files:**
- Create: `e2e/schedule.spec.js`

**Interfaces:**
- Consumes: `e2e/helpers.js` — `signInAs`, `navigateTo`, `scrubTo`; the page from Tasks 7–8.

The e2e DB is append-only across runs, so the applied write must be idempotent: the apply test uses `RescheduleProject` on **Platform Telemetry** (project 400 — zero allocations, zero timesheets, zero requirement rows, so the cascade is trivially repeatable) to the SAME fixed window every run. The nomination flow is exercised in preview only (an allocation apply would violate the overlap constraint on re-run).

- [ ] **Step 1: Write the spec**

`e2e/schedule.spec.js`:

```js
const { test, expect } = require("@playwright/test");
const { signInAs, navigateTo, scrubTo } = require("./helpers");

test("gaps surface and a nomination previews without saving", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const edge = page.locator("section", { hasText: "Edge Analytics" }).first();
  await expect(edge).toContainText("L3");
  await expect(edge).toContainText("2.0");

  await edge.getByRole("button", { name: "Edge Analytics" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByRole("button", { name: "Nominate" }).first().click();
  await inspector.getByRole("button", { name: /Marcus Chen/ }).click();

  await expect(edge).toContainText("1.5");
  await expect(edge).not.toContainText("2.0");

  await page.getByLabel("Preview").uncheck();
  await expect(edge).toContainText("2.0");
});

test("a reschedule outside the contract pills the project header", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const edge = page.locator("section", { hasText: "Edge Analytics" }).first();
  await edge.getByRole("button", { name: "Edge Analytics" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByLabel("Run start").fill("2026-05-01");

  await expect(edge).toContainText("outside the containing period");
});

test("applying a reschedule persists the new run window", async ({ page }) => {
  await signInAs(page, "Admin");
  await navigateTo(page, "Schedule");
  await scrubTo(page, "2026-06-15");

  const telemetry = page
    .locator("section", { hasText: "Platform Telemetry" })
    .first();
  await telemetry.getByRole("button", { name: "Platform Telemetry" }).click();
  const inspector = page.getByRole("complementary");
  await inspector.getByLabel("Run start").fill("2026-03-01");
  await inspector.getByLabel("Run end").fill("2027-01-01");
  await page.getByRole("button", { name: "Apply changes" }).click();

  await expect(telemetry).toContainText("2026-03-01 → 2027-01-01");
  await page.reload();
  await expect(
    page.locator("section", { hasText: "Platform Telemetry" }).first(),
  ).toContainText("2026-03-01 → 2027-01-01");
});
```

Adaptation notes: locator specifics (roles, labels) must match the markup Tasks 7–8 actually produced — give the run inputs `aria-label="Run start"` / `"Run end"` and the aside `role="complementary"` (`html.aside`) in Task 8 if not already; add "Schedule" to `helpers.js`' nav map if it keys labels. Assertions stay on visible text and roles, never classes. All three tests are idempotent: the first two never apply; the third applies the same window every run (a second run's reschedule to identical dates is a clean delete-and-reinsert of the same rows — note the demo seed's financials must not have invoiced project 400; if `bin/seed-invoices` did, switch the target to another allocation-free, invoice-free project and fix the dates accordingly).

- [ ] **Step 2: Run e2e**

Run: `TEMPO_DB_PORT=5435 bin/e2e e2e/schedule.spec.js > /tmp/e2e.log 2>&1; tail -20 /tmp/e2e.log`
Expected: 3 passed. (bin/e2e rebuilds the client bundle first — never skip it; stale bundles produce false failures.)

- [ ] **Step 3: Full gates**

Run: `TEMPO_DB_PORT=5435 bin/test > /tmp/gate.log 2>&1; tail -5 /tmp/gate.log && TEMPO_DB_PORT=5435 bin/e2e > /tmp/e2e-full.log 2>&1; tail -10 /tmp/e2e-full.log`
Expected: everything green, including the pre-existing suites.

- [ ] **Step 4: Commit**

```bash
git add e2e/schedule.spec.js
git commit -m "Add schedule e2e: gap preview, contract pill, reschedule apply

Nomination previews and reverts without saving; an out-of-contract
reschedule pills the project header; applying a reschedule to the
allocation-free Platform Telemetry persists idempotently across runs."
```

---

## Self-Review Notes

- **Spec coverage**: read model (T4), candidates (T5), endpoints + executor semantics incl. savepoints/annotations/all-or-nothing (T6), RescheduleProject cascade + guards (T2), shared types (T3), command codec + policy reuse (T1), client page/inspector/scenario chrome (T7–T8), e2e (T9). Seed task dropped deliberately: base seed already carries the demo gaps (spec's "extend the base seed" is satisfied by existing projects 100/500 — noted for the spec's tester).
- **Preview leaves-no-trace test** lives in T6 (`preview_leaves_the_database_unchanged_test`). Reschedule guards + containment: T2. Over-allocation flag: T6's savepoint test asserts it via the preview payload.
- **Known judgment calls the implementer may hit**: exact names in `test_pool`/`operations.gleam`/`request.gleam` helpers (read-and-mirror instructions given inline); squirrel's generated argument order; `gleam/time` date comparison helper name. Each is a rename, never a design change.

