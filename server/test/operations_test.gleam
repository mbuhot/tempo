//// Layer-2 operation tests (ARCHITECTURE.md §10.2, §5a). Apply each domain
//// operation to a known state, then assert the resulting facts AND exactly one
//// `event_log` row (operation/summary/payload, never `occurred_at` — the one
//// real-clock column).
////
//// ISOLATION (the approach subsequent agents follow). Operation tests MUTATE, so
//// they must not corrupt the shared migrated+seeded state the read-only tests
//// (sql_test/api_test) rely on. The dispatch seam exposes a transaction-free core
//// `command.dispatch_in(conn, …)` (production `dispatch` wraps it in one
//// transaction); each test runs its OWN `pog.transaction`, builds a minimal
//// test-local fixture, drives the operation through `dispatch_in` on that
//// connection, reads the resulting facts and the journal row back, then returns
//// `Error(…)` so the whole transaction rolls back — smuggling the read values out
//// through `TransactionRolledBack` (the same pattern as constraint_test/sql_test).
//// Nothing is ever committed, so the seed is undisturbed.
////
//// Fixtures are small and explicit, not the full seed. Identity ids
//// (engineer/contract/project) are minted by the operation under test or pinned
//// to high, test-local literals well clear of the seed range. The `_within_*`
//// PERIOD FKs are scoped per engineer/project id, so a fresh engineer cannot
//// collide with seeded facts.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/time/calendar.{
  April, Date, January, July, March, October, September,
}
import pog
import shared/codecs
import shared/types.{
  type Command, AdjustRateForPortion, AssignToProject, ChangeAllocationFraction,
  LogTimesheet, OnboardEngineer, Promote, ReviseRateCard, RollOff, SignContract,
  StartProject, TerminateEmployment,
}
import tempo/server/command
import tempo/server/context
import tempo/server/operation

// --- connection -------------------------------------------------------------

/// A single-connection pool per test. Each test owns its rolled-back transaction,
/// so one connection suffices; a tiny pool avoids exhausting PG's max_connections
/// across the concurrent gleeunit runner.
fn db() -> pog.Connection {
  let pool_name = process.new_name(prefix: "tempo_operations_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  started.data
}

// --- rollback harness -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value
/// out through `TransactionRolledBack` so the seed is never mutated.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Apply `command` through the dispatch seam on `conn`, asserting it succeeds.
fn apply(conn: pog.Connection, command: Command) -> Nil {
  let assert Ok(_) = command.dispatch_in(conn, "tester", command)
  Nil
}

// --- fixtures ---------------------------------------------------------------

/// Insert an engineer and return its minted id.
fn insert_engineer(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer (name) VALUES ($1) RETURNING id")
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

/// Insert a client and return its minted id.
fn insert_client(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO client (name) VALUES ($1) RETURNING id")
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

/// Run a parameterless statement, asserting it succeeds. Used for raw fixture
/// inserts (employment/role/allocation/contract/project) the test sets up before
/// the operation under test runs.
fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql)
    |> pog.execute(on: conn)
  Nil
}

// --- read-back helpers ------------------------------------------------------

/// One temporal fact rendered as plain text for exact assertions: a value plus
/// its `[from, to)` bounds (`to` is "" when the period is open-ended / NULL).
type Period {
  Period(value: String, valid_from: String, valid_to: String)
}

fn period_decoder() -> decode.Decoder(Period) {
  use value <- decode.field(0, decode.string)
  use valid_from <- decode.field(1, decode.string)
  use valid_to <- decode.field(2, decode.string)
  decode.success(Period(value:, valid_from:, valid_to:))
}

/// Read a single-engineer fact table back as `(value, from, to)` rows ordered by
/// start. `value_expr` selects the fact's payload (e.g. `level::text`,
/// `fraction::text`); `coalesce(upper(...)::text,'')` renders an open end as "".
fn read_periods(
  conn: pog.Connection,
  table: String,
  value_expr: String,
  period: String,
  where_clause: String,
) -> List(Period) {
  let sql =
    "SELECT "
    <> value_expr
    <> ", lower("
    <> period
    <> ")::text, coalesce(upper("
    <> period
    <> ")::text, '') "
    <> "FROM "
    <> table
    <> " WHERE "
    <> where_clause
    <> " ORDER BY lower("
    <> period
    <> ")"
  let assert Ok(returned) =
    pog.query(sql)
    |> pog.returning(period_decoder())
    |> pog.execute(on: conn)
  returned.rows
}

/// One journal row, minus the real-clock `occurred_at` (never asserted).
type Journal {
  Journal(actor: String, operation: String, summary: String, payload: String)
}

/// Read the whole `event_log` (this transaction's rows only — the seed leaves it
/// empty in test) newest-first, minus `occurred_at`.
fn read_journal(conn: pog.Connection) -> List(Journal) {
  let decoder = {
    use actor <- decode.field(0, decode.string)
    use operation <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    use payload <- decode.field(3, decode.string)
    decode.success(Journal(actor:, operation:, summary:, payload:))
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT actor, operation, summary, payload::text FROM event_log ORDER BY id DESC",
    )
    |> pog.returning(decoder)
    |> pog.execute(on: conn)
  returned.rows
}

// --- onboard_engineer (Assert × 3) ------------------------------------------

// Onboarding mints the identity and opens ongoing employment + role from the
// effective date, and appends one journal row. The board's containment chain
// holds: role ⊂ employment, both open-ended.
pub fn onboard_engineer_opens_employment_and_role_test() {
  let #(engineer_id, employment, role, journal) =
    rolling_back(fn(conn) {
      apply(conn, OnboardEngineer("Ada Lovelace", 5, Date(2026, January, 1)))
      let engineer_id = engineer_id_named(conn, "Ada Lovelace")
      let where_eng = "engineer_id = " <> int.to_string(engineer_id)
      #(
        engineer_id,
        read_periods(conn, "employment", "''", "employed_during", where_eng),
        read_periods(
          conn,
          "engineer_role",
          "level::text",
          "held_during",
          where_eng,
        ),
        read_journal(conn),
      )
    })

  // Open-ended employment from the effective date.
  assert employment == [Period("", "2026-01-01", "")]
  // One role at L5, open-ended from the effective date.
  assert role == [Period("5", "2026-01-01", "")]
  // Exactly one journal row: actor / operation / summary verbatim, and the
  // payload decoded back through the shared codec to the original command (never
  // the raw jsonb text, whose key order PG normalises; never occurred_at).
  let assert [row] = journal
  assert row.actor == "tester"
  assert row.operation == "onboard_engineer"
  assert row.summary
    == "Onboard Ada Lovelace at L5 (engineer "
    <> int.to_string(engineer_id)
    <> ") from 2026-01-01"
  assert json.parse(row.payload, codecs.command_decoder())
    == Ok(OnboardEngineer("Ada Lovelace", 5, Date(2026, January, 1)))
}

// --- promote (Change; the hard split-vs-scheduled-future case) --------------

// promote splits the role version covering the effective date — the new level
// lands on [effective, upper) and the [lower, effective) leftover keeps the OLD
// level — while a separately SCHEDULED FUTURE version (one that does not contain
// the effective date) is preserved untouched.
pub fn promote_splits_covering_version_but_preserves_scheduled_future_test() {
  let #(roles, journal) =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Grace Hopper")
      let where_eng = "engineer_id = " <> int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      // Two role versions: L4 covering H1, then a SCHEDULED FUTURE L6 from Oct.
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES "
          <> "("
          <> int.to_string(engineer_id)
          <> ", 4, daterange('2026-01-01','2026-10-01')), "
          <> "("
          <> int.to_string(engineer_id)
          <> ", 6, daterange('2026-10-01', NULL, '[)'))",
      )
      // Promote to L5 effective mid-year — lands inside the L4 version only.
      apply(conn, Promote(engineer_id, 5, Date(2026, July, 1)))
      #(
        read_periods(
          conn,
          "engineer_role",
          "level::text",
          "held_during",
          where_eng,
        ),
        read_journal(conn),
      )
    })

  // L4 leftover [Jan,Jul), bumped L5 [Jul,Oct), untouched scheduled L6 [Oct,∞).
  assert roles
    == [
      Period("4", "2026-01-01", "2026-07-01"),
      Period("5", "2026-07-01", "2026-10-01"),
      Period("6", "2026-10-01", ""),
    ]
  // Exactly one journal row (its summary/payload are pinned by the dedicated
  // payload test, which knows the minted engineer id).
  assert list.length(journal) == 1
}

// --- terminate_employment (Close/cascade; rejected when a timesheet outlives) -

// A clean termination caps every contained fact (allocation/leave/role) to the
// end date and then caps employment — children before parent. With no fact
// outliving the end, the cascade commits.
pub fn terminate_employment_caps_children_then_employment_test() {
  let #(employment, role, allocation, journal) =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Katherine Johnson")
      let client_id = insert_client(conn, "NASA Langley")
      let where_eng = "engineer_id = " <> int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 5, daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO contract (id, client_id, term) VALUES (90001, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project (id, contract_id, name, active_during) VALUES "
          <> "(80001, 90001, 'Orbital Mechanics', daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 80001, 1.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Terminate from Sep 1: every open-ended child caps to [Jan,Sep).
      apply(conn, TerminateEmployment(engineer_id, Date(2026, September, 1)))
      #(
        read_periods(conn, "employment", "''", "employed_during", where_eng),
        read_periods(
          conn,
          "engineer_role",
          "level::text",
          "held_during",
          where_eng,
        ),
        read_periods(
          conn,
          "allocation",
          "fraction::text",
          "allocated_during",
          where_eng <> " AND project_id = 80001",
        ),
        read_journal(conn),
      )
    })

  assert employment == [Period("", "2026-01-01", "2026-09-01")]
  assert role == [Period("5", "2026-01-01", "2026-09-01")]
  assert allocation == [Period("1.00", "2026-01-01", "2026-09-01")]
  // One journal row recorded the termination (summary/payload pinned below by
  // the dedicated payload test).
  assert list.length(journal) == 1
}

// terminate_employment is REJECTED (ContainmentViolated) when a timesheet day
// would outlive the capped allocation: capping the allocation to [Jan,Mar)
// leaves the logged April day dangling, so the allocation PERIOD FK from
// timesheet (timesheet_within_allocation) blocks the cascade and the whole
// transaction is undone (the facts are left intact).
pub fn terminate_employment_rejected_when_timesheet_outlives_end_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Margaret Hamilton")
      let client_id = insert_client(conn, "MIT Draper")
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 5, daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO contract (id, client_id, term) VALUES (90002, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project (id, contract_id, name, active_during) VALUES "
          <> "(80002, 90002, 'Apollo Guidance', daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 80002, 1.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // A logged day in April — past the intended March termination.
      exec(
        conn,
        "INSERT INTO timesheet (engineer_id, project_id, work_day, hours) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 80002, daterange('2026-04-10','2026-04-11'), 8.00)",
      )
      // Terminate from Mar 1: capping the allocation to [Jan,Mar) would strand
      // the April timesheet day; the PERIOD FK rejects the cascade.
      command.dispatch_in(
        conn,
        "tester",
        TerminateEmployment(engineer_id, Date(2026, March, 1)),
      )
    })

  assert outcome
    == Error(operation.ContainmentViolated("timesheet_within_allocation"))
}

// --- retroactive change covering the whole fact erases the prior value -------

// A change whose effective date is at/before a fact's start covers the whole
// span, so FOR PORTION OF yields ZERO leftovers and the prior assertion is
// erased — a correction IS a retroactive change (ADR-021). Promoting from the
// exact start date leaves a single row at the new level with no fragments.
pub fn retroactive_promote_covering_whole_fact_leaves_no_leftover_test() {
  let roles =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Radia Perlman")
      let where_eng = "engineer_id = " <> int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 4, daterange('2026-01-01', NULL, '[)'))",
      )
      // Promote effective from the SAME start date: covers the whole L4 row, so
      // there is no [lower, effective) leftover — the L4 assertion is erased.
      apply(conn, Promote(engineer_id, 5, Date(2026, January, 1)))
      read_periods(
        conn,
        "engineer_role",
        "level::text",
        "held_during",
        where_eng,
      )
    })

  assert roles == [Period("5", "2026-01-01", "")]
}

// --- allocation aggregate (Assert / Change / Close) -------------------------

/// Set up an employed engineer (open-ended employment + L5 role) and an
/// open-ended project under a fresh contract, so allocation operations have both
/// PERIOD-FK parents. Returns the minted engineer id; the project is `project_id`.
fn employed_engineer_on_project(
  conn: pog.Connection,
  name: String,
  client: String,
  contract_id: Int,
  project_id: Int,
) -> Int {
  let engineer_id = insert_engineer(conn, name)
  let client_id = insert_client(conn, client)
  exec(
    conn,
    "INSERT INTO employment (engineer_id, employed_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
      <> int.to_string(engineer_id)
      <> ", 5, daterange('2026-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO contract (id, client_id, term) VALUES ("
      <> int.to_string(contract_id)
      <> ", "
      <> int.to_string(client_id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO project (id, contract_id, name, active_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(contract_id)
      <> ", 'Test Project', daterange('2026-01-01', NULL, '[)'))",
  )
  engineer_id
}

// assign_to_project opens an allocation over [valid_from, valid_to);
// change_allocation_fraction from a date splits it (the [lower, effective)
// leftover keeps the OLD fraction, [effective, upper) takes the new one); roll_off
// then caps the remaining tail at a date.
pub fn allocation_assign_change_then_roll_off_test() {
  let fractions =
    rolling_back(fn(conn) {
      let engineer_id =
        employed_engineer_on_project(
          conn,
          "Sophie Wilson",
          "Acorn",
          90_010,
          80_010,
        )
      let where_alloc =
        "engineer_id = "
        <> int.to_string(engineer_id)
        <> " AND project_id = 80010"
      // Assert: open-ended 0.5 from Jan.
      apply(
        conn,
        AssignToProject(
          engineer_id,
          80_010,
          0.5,
          Date(2026, January, 1),
          Date(2027, January, 1),
        ),
      )
      // Change: 1.0 from Jul — splits at Jul, the Jan..Jul leftover stays 0.5.
      apply(
        conn,
        ChangeAllocationFraction(engineer_id, 80_010, 1.0, Date(2026, July, 1)),
      )
      // Close: roll off from Oct — caps the open 1.0 tail to [Jul, Oct).
      apply(conn, RollOff(engineer_id, 80_010, Date(2026, October, 1)))
      read_periods(
        conn,
        "allocation",
        "fraction::text",
        "allocated_during",
        where_alloc,
      )
    })

  assert fractions
    == [
      Period("0.50", "2026-01-01", "2026-07-01"),
      Period("1.00", "2026-07-01", "2026-10-01"),
    ]
}

// --- log_timesheet through the dispatch seam (timesheet reuse) --------------

// LogTimesheet routes through the EXISTING timesheet temporal-upsert core and
// records one journal row. The day is covered by the allocation, so the
// timesheet PERIOD FK is satisfied and the entry persists.
pub fn log_timesheet_through_dispatch_persists_and_journals_test() {
  let #(hours, journal_ops) =
    rolling_back(fn(conn) {
      let engineer_id =
        employed_engineer_on_project(
          conn,
          "Tony Hoare",
          "Elliott",
          90_011,
          80_011,
        )
      apply(
        conn,
        AssignToProject(
          engineer_id,
          80_011,
          1.0,
          Date(2026, January, 1),
          Date(2027, January, 1),
        ),
      )
      apply(conn, LogTimesheet(engineer_id, 80_011, Date(2026, March, 10), 7.5))
      let where_ts =
        "engineer_id = "
        <> int.to_string(engineer_id)
        <> " AND project_id = 80011"
      let hours =
        read_periods(conn, "timesheet", "hours::text", "work_day", where_ts)
      let ops = list.map(read_journal(conn), fn(row) { row.operation })
      #(hours, ops)
    })

  // One single-day timesheet row at the logged hours.
  assert hours == [Period("7.50", "2026-03-10", "2026-03-11")]
  // Two journal rows newest-first: the timesheet log, then the assignment.
  assert journal_ops == ["log_timesheet", "assign_to_project"]
}

// A LogTimesheet for a day NOT covered by any allocation is rejected by the
// timesheet PERIOD FK and surfaces as the unified ContainmentViolated (the same
// classification every other containment FK gets), proving the reuse path
// re-classifies the domain's NotAllocated through the operation error type.
pub fn log_timesheet_without_allocation_is_containment_violated_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id =
        employed_engineer_on_project(
          conn,
          "Edsger Dijkstra",
          "THE",
          90_012,
          80_012,
        )
      // No allocation at all — the logged day has no covering allocation.
      command.dispatch_in(
        conn,
        "tester",
        LogTimesheet(engineer_id, 80_012, Date(2026, March, 10), 8.0),
      )
    })

  assert outcome
    == Error(operation.ContainmentViolated("timesheet_within_allocation"))
}

// --- summary / payload (the journal contract, never occurred_at) ------------

// dispatch writes exactly one journal row per command, carrying the actor, the
// operation tag, the terse human summary, and the command re-encoded via the
// shared codec as the payload. The payload is asserted by decoding it BACK
// through the codec to the original `Command` (semantic equality): PG stores it
// as `jsonb`, which normalises object-key order, so the raw text is not a stable
// contract — the round-trip the client actually performs is.
pub fn dispatch_records_operation_summary_and_payload_test() {
  let command =
    Promote(engineer_id: 0, level: 5, effective: Date(2026, July, 1))
  let #(engineer_id, rows) =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Barbara Liskov")
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 4, daterange('2026-01-01', NULL, '[)'))",
      )
      apply(conn, Promote(..command, engineer_id:))
      #(engineer_id, read_journal(conn))
    })

  let id = int.to_string(engineer_id)
  let assert [row] = rows
  // actor / operation / summary asserted verbatim.
  assert row.actor == "tester"
  assert row.operation == "promote"
  assert row.summary == "Promote engineer " <> id <> " to L5 from 2026-07-01"
  // payload decoded back through the shared codec equals the dispatched command.
  assert json.parse(row.payload, codecs.command_decoder())
    == Ok(Promote(..command, engineer_id:))
}

// --- rate_card aggregate (Surgical / Change) --------------------------------

// adjust_rate_for_portion bumps a level's rate for a BOUNDED window, splitting the
// covering rate_card row three ways: the [from, to) sub-period takes the new rate
// while the before/after remainders are carved off as their own rows at the old
// rate. The rate_card key is (level, effective_during) — no engineer scoping — so
// the fixture uses L1, a level the seed leaves empty, and reads back WHERE level=1.
pub fn adjust_rate_for_portion_splits_three_ways_test() {
  let rates =
    rolling_back(fn(conn) {
      // One open-ended L1 version at 500 from Jan.
      exec(
        conn,
        "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
          <> "(1, 500.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Bump to 600 for the bounded window [Apr, Jul) only.
      apply(
        conn,
        AdjustRateForPortion(
          1,
          600.0,
          Date(2026, April, 1),
          Date(2026, July, 1),
        ),
      )
      read_periods(
        conn,
        "rate_card",
        "day_rate::text",
        "effective_during",
        "level = 1",
      )
    })

  // before [Jan,Apr) 500, during [Apr,Jul) 600, after [Jul,∞) 500.
  assert rates
    == [
      Period("500.00", "2026-01-01", "2026-04-01"),
      Period("600.00", "2026-04-01", "2026-07-01"),
      Period("500.00", "2026-07-01", ""),
    ]
}

// revise_rate_card re-rates a level from a date onward (the Change pattern): it
// splits the version covering the effective date — the new rate lands on
// [effective, upper) and the [lower, effective) leftover keeps the OLD rate —
// while a separately SCHEDULED FUTURE version (one not containing the effective
// date) is preserved untouched.
pub fn revise_rate_card_caps_from_date_preserving_scheduled_future_test() {
  let rates =
    rolling_back(fn(conn) {
      // Two L2 versions: 700 covering H1, then a SCHEDULED FUTURE 900 from Oct.
      exec(
        conn,
        "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
          <> "(2, 700.00, daterange('2026-01-01','2026-07-01')), "
          <> "(2, 900.00, daterange('2026-10-01', NULL, '[)'))",
      )
      // Revise to 800 effective Apr — lands inside the 700 version only.
      apply(conn, ReviseRateCard(2, 800.0, Date(2026, April, 1)))
      read_periods(
        conn,
        "rate_card",
        "day_rate::text",
        "effective_during",
        "level = 2",
      )
    })

  // 700 leftover [Jan,Apr), revised 800 [Apr,Jul), untouched scheduled 900 [Oct,∞).
  assert rates
    == [
      Period("700.00", "2026-01-01", "2026-04-01"),
      Period("800.00", "2026-04-01", "2026-07-01"),
      Period("900.00", "2026-10-01", ""),
    ]
}

// --- engagement aggregate (Assert × 2; PERIOD-FK containment) ---------------

// sign_contract inserts a contract term (minting the entity id, resolving the
// client by name) and start_project inserts a project under it (minting its id).
// A project whose active period falls WITHIN the contract term satisfies the
// project_within_contract PERIOD FK, so both persist and each journals one row.
pub fn sign_contract_then_start_project_within_term_persists_test() {
  let #(contract, project, journal_ops) =
    rolling_back(fn(conn) {
      let client_id = insert_client(conn, "Initech")
      // Contract over [Jan 2026, Jan 2027).
      apply(
        conn,
        SignContract("Initech", Date(2026, January, 1), Date(2027, January, 1)),
      )
      let contract_id = contract_id_for_client(conn, client_id)
      // Project active [Mar, Oct) — inside the contract term.
      apply(
        conn,
        StartProject(
          "TPS Reports",
          contract_id,
          Date(2026, March, 1),
          Date(2026, October, 1),
        ),
      )
      #(
        read_periods(
          conn,
          "contract",
          "client_id::text",
          "term",
          "client_id = " <> int.to_string(client_id),
        ),
        read_periods(
          conn,
          "project",
          "name",
          "active_during",
          "contract_id = " <> int.to_string(contract_id),
        ),
        list.map(read_journal(conn), fn(row) { row.operation }),
      )
    })

  // The contract term and the project active period, read back as facts.
  let assert [contract_row] = contract
  assert contract_row.valid_from == "2026-01-01"
  assert contract_row.valid_to == "2027-01-01"
  assert project == [Period("TPS Reports", "2026-03-01", "2026-10-01")]
  // Two journal rows newest-first: the project start, then the contract signing.
  assert journal_ops == ["start_project", "sign_contract"]
}

// start_project is REJECTED (ContainmentViolated) when the project's active
// period extends past the contract's term: the project_within_contract PERIOD FK
// rejects a project not fully contained by its contract, undoing the transaction.
pub fn start_project_outside_contract_term_is_containment_violated_test() {
  let outcome =
    rolling_back(fn(conn) {
      let client_id = insert_client(conn, "Hooli")
      // Contract bounded to [Jan, Jul) 2026.
      apply(
        conn,
        SignContract("Hooli", Date(2026, January, 1), Date(2026, July, 1)),
      )
      let contract_id = contract_id_for_client(conn, client_id)
      // Project active [Mar, Oct) — runs past the contract's Jul end.
      command.dispatch_in(
        conn,
        "tester",
        StartProject(
          "Nucleus",
          contract_id,
          Date(2026, March, 1),
          Date(2026, October, 1),
        ),
      )
    })

  assert outcome
    == Error(operation.ContainmentViolated("project_within_contract"))
}

// --- helpers ----------------------------------------------------------------

/// The id of the contract minted for `client_id` (used after sign_contract mints
/// it; the test client owns exactly one contract).
fn contract_id_for_client(conn: pog.Connection, client_id: Int) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM contract WHERE client_id = $1")
    |> pog.parameter(pog.int(client_id))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}

/// The id of the engineer with `name` (used after onboarding mints it).
fn engineer_id_named(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("SELECT id FROM engineer WHERE name = $1")
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}
