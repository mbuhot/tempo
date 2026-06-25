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
import gleam/int
import gleam/json
import gleam/list
import gleam/time/calendar.{
  April, August, Date, January, July, March, October, September,
}
import pog
import shared/allocation/command as allocation_command
import shared/client_details/command as client_details_command
import shared/command.{type Command} as gateway
import shared/engagement/command as engagement_command
import shared/engineer/command as engineer_command
import shared/project_requirement/command as project_requirement_command
import shared/rate_card/command as rate_card_command
import shared/salary/command as salary_command
import shared/timesheet/command as timesheet_command
import tempo/server/command
import tempo/server/operation
import test_pool

// --- rollback harness -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value
/// out through `TransactionRolledBack` so the seed is never mutated.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Apply `command` through the dispatch seam on `conn`, asserting it succeeds.
fn apply(conn: pog.Connection, command: Command) -> Nil {
  let assert Ok(_) = command.dispatch_in(conn, "tester", command)
  Nil
}

// --- fixtures ---------------------------------------------------------------

/// Insert an engineer (ID-ONLY anchor) plus a founding engineer_contact row
/// carrying `name`, and return the minted id. The name now lives in the contact
/// fact (read via the engineer_current view), not on the anchor.
fn insert_engineer(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO engineer DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO engineer_contact "
      <> "(engineer_id, name, email, phone, postal_address, recorded_during) "
      <> "VALUES ($1, $2, '', '', '', daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: conn)
  id
}

/// Insert a client and return its minted id.
fn insert_client(conn: pog.Connection, name: String) -> Int {
  let row_decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(id)
  }
  let assert Ok(returned) =
    pog.query("INSERT INTO client DEFAULT VALUES RETURNING id")
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  let assert Ok(_) =
    pog.query(
      "INSERT INTO client_profile "
      <> "(client_id, name, recorded_during) "
      <> "VALUES ($1, $2, daterange('2024-01-01', NULL, '[)'))",
    )
    |> pog.parameter(pog.int(id))
    |> pog.parameter(pog.text(name))
    |> pog.execute(on: conn)
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

/// Read this transaction's `event_log` rows newest-first, minus `occurred_at`. The
/// seed records its founding history under actor `seed`; these tests dispatch under
/// `tester`, so the `actor <> 'seed'` filter isolates the rows this test wrote.
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
      "SELECT actor, operation, summary, payload::text FROM event_log"
      <> " WHERE actor <> 'seed' ORDER BY id DESC",
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
      apply(
        conn,
        gateway.EngineerCommand(engineer_command.OnboardEngineer(
          "Ada Lovelace",
          5,
          Date(2026, January, 1),
        )),
      )
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
  assert json.parse(row.payload, gateway.command_decoder())
    == Ok(
      gateway.EngineerCommand(engineer_command.OnboardEngineer(
        "Ada Lovelace",
        5,
        Date(2026, January, 1),
      )),
    )
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
      // Promote to L5 effective mid-year with no upper bound — asserts L5 from
      // July to infinity, so the scheduled L6 from Oct is superseded.
      apply(
        conn,
        gateway.EngineerCommand(engineer_command.Promote(
          engineer_id,
          5,
          Date(2026, July, 1),
        )),
      )
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

  // L4 leftover [Jan,Jul), L5 open-ended [Jul,∞) — scheduled L6 superseded
  // because the promote carries no upper bound (valid to infinity).
  assert roles
    == [
      Period("4", "2026-01-01", "2026-07-01"),
      Period("5", "2026-07-01", ""),
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
      exec(conn, "INSERT INTO contract (id) VALUES (90001)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90001, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80001)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES "
          <> "(80001, 'Orbital Mechanics', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80001, 90001, daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 80001, 1.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Terminate from Sep 1: every open-ended child caps to [Jan,Sep).
      apply(
        conn,
        gateway.EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id,
          Date(2026, September, 1),
        )),
      )
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
      exec(conn, "INSERT INTO contract (id) VALUES (90002)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90002, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80002)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES "
          <> "(80002, 'Apollo Guidance', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80002, 90002, daterange('2026-01-01', NULL, '[)'))",
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
        gateway.EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id,
          Date(2026, March, 1),
        )),
      )
    })

  assert outcome
    == Error(operation.ContainmentViolated("timesheet_within_allocation"))
}

// Terminating employment deletes scheduled future role and allocation rows that
// start after the termination date, not just caps rows straddling the date.
pub fn terminate_employment_deletes_scheduled_future_facts_test() {
  let #(roles, allocation, employment) =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Hedy Lamarr")
      let client_id = insert_client(conn, "Frequency Labs")
      let where_eng = "engineer_id = " <> int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES "
          <> "("
          <> int.to_string(engineer_id)
          <> ", 5, daterange('2026-01-01','2026-09-01')), "
          <> "("
          <> int.to_string(engineer_id)
          <> ", 6, daterange('2026-09-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO contract (id) VALUES (90003)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90003, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80003)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES "
          <> "(80003, 'Spread Spectrum', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80003, 90003, daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES ("
          <> int.to_string(engineer_id)
          <> ", 80003, 1.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Terminate at Mar 1: clips L5 [Jan,Sep) to [Jan,Mar), deletes the
      // scheduled L6 [Sep,∞) entirely, and caps the allocation to [Jan,Mar).
      apply(
        conn,
        gateway.EngineerCommand(engineer_command.TerminateEmployment(
          engineer_id,
          Date(2026, March, 1),
        )),
      )
      #(
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
          where_eng <> " AND project_id = 80003",
        ),
        read_periods(conn, "employment", "''", "employed_during", where_eng),
      )
    })

  assert roles == [Period("5", "2026-01-01", "2026-03-01")]
  assert allocation == [Period("1.00", "2026-01-01", "2026-03-01")]
  assert employment == [Period("", "2026-01-01", "2026-03-01")]
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
      apply(
        conn,
        gateway.EngineerCommand(engineer_command.Promote(
          engineer_id,
          5,
          Date(2026, January, 1),
        )),
      )
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
    "INSERT INTO contract (id) VALUES (" <> int.to_string(contract_id) <> ")",
  )
  exec(
    conn,
    "INSERT INTO contract_terms (contract_id, client_id, term) VALUES ("
      <> int.to_string(contract_id)
      <> ", "
      <> int.to_string(client_id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO project (id) VALUES (" <> int.to_string(project_id) <> ")",
  )
  exec(
    conn,
    "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES ("
      <> int.to_string(project_id)
      <> ", 'Test Project', '', daterange('2024-01-01', NULL, '[)'))",
  )
  exec(
    conn,
    "INSERT INTO project_run (project_id, contract_id, active_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(contract_id)
      <> ", daterange('2026-01-01', NULL, '[)'))",
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
        gateway.AllocationCommand(allocation_command.AssignToProject(
          engineer_id,
          80_010,
          0.5,
          Date(2026, January, 1),
          Date(2027, January, 1),
        )),
      )
      // Change: 1.0 from Jul — splits at Jul, the Jan..Jul leftover stays 0.5.
      apply(
        conn,
        gateway.AllocationCommand(allocation_command.ChangeAllocationFraction(
          engineer_id,
          80_010,
          1.0,
          Date(2026, July, 1),
        )),
      )
      // Close: roll off from Oct — caps the open 1.0 tail to [Jul, Oct).
      apply(
        conn,
        gateway.AllocationCommand(allocation_command.RollOff(
          engineer_id,
          80_010,
          Date(2026, October, 1),
        )),
      )
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

// assign_to_project guards the allocation window against the engineer's employment
// BEFORE the write: an assignment running past the engineer's employment end is
// refused as EngineerNotEmployed (a clear domain error, ahead of the
// allocation_within_employment containment FK). Employment ends 2026-06-01 but the
// assignment runs to 2026-08-01; the project runs open-ended, so only employment is
// at fault.
pub fn assign_past_employment_is_rejected_test() {
  let #(engineer_id, outcome) =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Sophie Wilson")
      let client_id = insert_client(conn, "Acorn")
      let id = int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> id
          <> ", daterange('2026-01-01','2026-06-01'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> id
          <> ", 5, daterange('2026-01-01','2026-06-01'))",
      )
      exec(conn, "INSERT INTO contract (id) VALUES (90020)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90020, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80020)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) "
          <> "VALUES (80020, 'Past', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80020, 90020, daterange('2026-01-01', NULL, '[)'))",
      )
      let outcome =
        command.dispatch_in(
          conn,
          "tester",
          gateway.AllocationCommand(allocation_command.AssignToProject(
            engineer_id,
            80_020,
            0.5,
            Date(2026, January, 1),
            Date(2026, August, 1),
          )),
        )
      #(engineer_id, outcome)
    })

  let assert Error(operation.EngineerNotEmployed(
    engineer_id: rejected,
    valid_from:,
    valid_to:,
  )) = outcome
  assert rejected == engineer_id
  assert valid_from == Date(2026, January, 1)
  assert valid_to == Date(2026, August, 1)
}

// The project-side analogue: the engineer is employed open-ended, but the project's
// RUN ends 2026-06-01 while the assignment runs to 2026-08-01, so it is refused as
// ProjectNotRunning ahead of the allocation_within_project containment FK.
pub fn assign_past_project_run_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Roger Wilson")
      let client_id = insert_client(conn, "Acorn")
      let id = int.to_string(engineer_id)
      exec(
        conn,
        "INSERT INTO employment (engineer_id, employed_during) VALUES ("
          <> id
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO engineer_role (engineer_id, level, held_during) VALUES ("
          <> id
          <> ", 5, daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO contract (id) VALUES (90021)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90021, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80021)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) "
          <> "VALUES (80021, 'Short Run', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80021, 90021, daterange('2026-01-01','2026-06-01'))",
      )
      command.dispatch_in(
        conn,
        "tester",
        gateway.AllocationCommand(allocation_command.AssignToProject(
          engineer_id,
          80_021,
          0.5,
          Date(2026, January, 1),
          Date(2026, August, 1),
        )),
      )
    })

  let assert Error(operation.ProjectNotRunning(
    project_id:,
    valid_from:,
    valid_to:,
  )) = outcome
  assert project_id == 80_021
  assert valid_from == Date(2026, January, 1)
  assert valid_to == Date(2026, August, 1)
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
        gateway.AllocationCommand(allocation_command.AssignToProject(
          engineer_id,
          80_011,
          1.0,
          Date(2026, January, 1),
          Date(2027, January, 1),
        )),
      )
      apply(
        conn,
        gateway.TimesheetCommand(timesheet_command.LogTimesheet(
          engineer_id,
          80_011,
          Date(2026, March, 10),
          7.5,
        )),
      )
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
        gateway.TimesheetCommand(timesheet_command.LogTimesheet(
          engineer_id,
          80_012,
          Date(2026, March, 10),
          8.0,
        )),
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
    engineer_command.Promote(
      engineer_id: 0,
      level: 5,
      effective: Date(2026, July, 1),
    )
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
      apply(
        conn,
        gateway.EngineerCommand(
          engineer_command.Promote(..command, engineer_id:),
        ),
      )
      #(engineer_id, read_journal(conn))
    })

  let id = int.to_string(engineer_id)
  let assert [row] = rows
  // actor / operation / summary asserted verbatim.
  assert row.actor == "tester"
  assert row.operation == "promote"
  assert row.summary == "Promote engineer " <> id <> " to L5 from 2026-07-01"
  // payload decoded back through the shared codec equals the dispatched command.
  assert json.parse(row.payload, gateway.command_decoder())
    == Ok(gateway.EngineerCommand(
      engineer_command.Promote(..command, engineer_id:),
    ))
}

// A command records exactly one journal event, so dispatch returns that single
// `Event` directly — not a one-element list the caller must destructure. Binding
// `Ok(event)` and reading `event.operation` is the narrowed contract: it would not
// compile against a `List(Event)` return.
pub fn dispatch_returns_the_single_recorded_event_test() {
  let event =
    rolling_back(fn(conn) {
      let engineer_id = insert_engineer(conn, "Grace Hopper")
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
      let assert Ok(event) =
        command.dispatch_in(
          conn,
          "tester",
          gateway.EngineerCommand(engineer_command.Promote(
            engineer_id,
            5,
            Date(2026, July, 1),
          )),
        )
      event
    })

  assert event.actor == "tester"
  assert event.operation == "promote"
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
      exec(conn, "DELETE FROM rate_card WHERE level = 1")
      exec(
        conn,
        "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
          <> "(1, 500.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Bump to 600 for the bounded window [Apr, Jul) only.
      apply(
        conn,
        gateway.RateCardCommand(rate_card_command.AdjustRateForPortion(
          1,
          600.0,
          Date(2026, April, 1),
          Date(2026, July, 1),
        )),
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
      exec(conn, "DELETE FROM rate_card WHERE level = 2")
      exec(
        conn,
        "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
          <> "(2, 700.00, daterange('2026-01-01','2026-07-01')), "
          <> "(2, 900.00, daterange('2026-10-01', NULL, '[)'))",
      )
      // Revise to 800 effective Apr — lands inside the 700 version only.
      apply(
        conn,
        gateway.RateCardCommand(rate_card_command.ReviseRateCard(
          2,
          800.0,
          Date(2026, April, 1),
        )),
      )
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

// revise_rate_card is REJECTED (NoSuchVersion) when no rate_card version covers the
// effective date: the FOR PORTION OF UPDATE matches zero rows, so rather than
// journalling a billing-rate change that never happened it fails with a typed
// error and the transaction is undone. The fixture empties L1 (which the seed
// leaves clear) so the level has no covering version at all.
pub fn revise_rate_card_with_no_covering_version_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      exec(conn, "DELETE FROM rate_card WHERE level = 1")
      command.dispatch_in(
        conn,
        "tester",
        gateway.RateCardCommand(rate_card_command.ReviseRateCard(
          1,
          800.0,
          Date(2026, April, 1),
        )),
      )
    })

  assert outcome == Error(operation.NoSuchVersion)
}

// --- salary aggregate (Change) ----------------------------------------------

// set_salary re-rates a level's monthly salary from a date onward (the Change
// pattern, the cost analogue of revise_rate_card): it splits the version covering
// the effective date — the new salary lands on [effective, upper) and the
// [lower, effective) leftover keeps the OLD salary.
pub fn set_salary_caps_from_date_splitting_covering_version_test() {
  let salaries =
    rolling_back(fn(conn) {
      // One open-ended L2 salary of 4000 from Jan.
      exec(conn, "DELETE FROM salary WHERE level = 2")
      exec(
        conn,
        "INSERT INTO salary (level, monthly_salary, effective_during) VALUES "
          <> "(2, 4000.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Set 5000 effective Apr — splits the 4000 version at Apr.
      apply(
        conn,
        gateway.SalaryCommand(salary_command.SetSalary(
          2,
          5000.0,
          Date(2026, April, 1),
        )),
      )
      read_periods(
        conn,
        "salary",
        "monthly_salary::text",
        "effective_during",
        "level = 2",
      )
    })

  // 4000 leftover [Jan,Apr), revised 5000 [Apr,∞).
  assert salaries
    == [
      Period("4000.00", "2026-01-01", "2026-04-01"),
      Period("5000.00", "2026-04-01", ""),
    ]
}

// set_salary is REJECTED (NoSuchVersion) when no salary version covers the
// effective date: the FOR PORTION OF UPDATE matches zero rows, so rather than
// journalling a salary change that never happened (which payroll would ignore) it
// fails with a typed error and the transaction is undone. The fixture empties L1
// so the level has no covering version at all.
pub fn set_salary_with_no_covering_version_is_rejected_test() {
  let outcome =
    rolling_back(fn(conn) {
      exec(conn, "DELETE FROM salary WHERE level = 1")
      command.dispatch_in(
        conn,
        "tester",
        gateway.SalaryCommand(salary_command.SetSalary(
          1,
          5000.0,
          Date(2026, April, 1),
        )),
      )
    })

  assert outcome == Error(operation.NoSuchVersion)
}

// --- project_requirement aggregate (Surgical, the demand side) --------------

// set_project_requirement sets a project's capacity demand for a BOUNDED window,
// splitting the covering requirement row three ways: the [from, to) sub-period
// takes the new quantity while the before/after remainders are carved off as
// their own rows at the old quantity — the same FOR-PORTION-OF clear-then-set as
// rate_card, but scoped by (project_id, level) and contained by the project's run.
pub fn set_project_requirement_for_portion_splits_three_ways_test() {
  let quantities =
    rolling_back(fn(conn) {
      // A project running open-ended from Jan, so the requirement's PERIOD FK
      // (requirement_within_project) is satisfied for any window from Jan on.
      let client_id = insert_client(conn, "Initech")
      exec(conn, "INSERT INTO contract (id) VALUES (90020)")
      exec(
        conn,
        "INSERT INTO contract_terms (contract_id, client_id, term) VALUES (90020, "
          <> int.to_string(client_id)
          <> ", daterange('2026-01-01', NULL, '[)'))",
      )
      exec(conn, "INSERT INTO project (id) VALUES (80020)")
      exec(
        conn,
        "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES "
          <> "(80020, 'Edge Analytics', '', daterange('2024-01-01', NULL, '[)'))",
      )
      exec(
        conn,
        "INSERT INTO project_run (project_id, contract_id, active_during) VALUES "
          <> "(80020, 90020, daterange('2026-01-01', NULL, '[)'))",
      )
      // One open-ended L3 demand of 2 FTE from Jan.
      exec(
        conn,
        "INSERT INTO project_requirement (project_id, level, quantity, required_during) VALUES "
          <> "(80020, 3, 2.00, daterange('2026-01-01', NULL, '[)'))",
      )
      // Set 1 FTE for the bounded window [Apr, Jul) only.
      apply(
        conn,
        gateway.ProjectRequirementCommand(
          project_requirement_command.SetProjectRequirement(
            80_020,
            3,
            1.0,
            Date(2026, April, 1),
            Date(2026, July, 1),
          ),
        ),
      )
      read_periods(
        conn,
        "project_requirement",
        "quantity::text",
        "required_during",
        "project_id = 80020 AND level = 3",
      )
    })

  // before [Jan,Apr) 2.00, during [Apr,Jul) 1.00, after [Jul,∞) 2.00.
  assert quantities
    == [
      Period("2.00", "2026-01-01", "2026-04-01"),
      Period("1.00", "2026-04-01", "2026-07-01"),
      Period("2.00", "2026-07-01", ""),
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
        gateway.EngagementCommand(engagement_command.SignContract(
          "Initech",
          Date(2026, January, 1),
          Date(2027, January, 1),
        )),
      )
      let contract_id = contract_id_for_client(conn, client_id)
      // Project active [Mar, Oct) — inside the contract term.
      apply(
        conn,
        gateway.EngagementCommand(engagement_command.StartProject(
          "TPS Reports",
          contract_id,
          Date(2026, March, 1),
          Date(2026, October, 1),
        )),
      )
      #(
        read_periods(
          conn,
          "contract_terms",
          "client_id::text",
          "term",
          "client_id = " <> int.to_string(client_id),
        ),
        // The project NAME is now project_profile.title and the active window is
        // project_run.active_during, so read the two together joined on project_id.
        read_periods(
          conn,
          "(project_run JOIN project_current ON project_current.id = project_run.project_id) j",
          "j.title",
          "j.active_during",
          "j.contract_id = " <> int.to_string(contract_id),
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
        gateway.EngagementCommand(engagement_command.SignContract(
          "Hooli",
          Date(2026, January, 1),
          Date(2026, July, 1),
        )),
      )
      let contract_id = contract_id_for_client(conn, client_id)
      // Project active [Mar, Oct) — runs past the contract's Jul end.
      command.dispatch_in(
        conn,
        "tester",
        gateway.EngagementCommand(engagement_command.StartProject(
          "Nucleus",
          contract_id,
          Date(2026, March, 1),
          Date(2026, October, 1),
        )),
      )
    })

  assert outcome
    == Error(operation.ContainmentViolated("project_within_contract"))
}

// --- client_details aggregate (Change; the single-variant route arm) --------

// UpdateClientProfile routes through the client_details aggregate — a
// single-variant arm whose handler had no command shape left to disambiguate.
// It re-states the client's name from the effective date onward (the Change
// pattern), splitting the version covering that date, and records one journal
// row tagged update_client_profile. This pins that the narrowed route arm still
// reaches the right handler and records the right fact.
pub fn update_client_profile_changes_name_and_journals_test() {
  let #(profiles, journal_ops) =
    rolling_back(fn(conn) {
      let client_id = insert_client(conn, "Initech")
      // Re-state the name from Apr — splits the open-ended Initech row at Apr.
      apply(
        conn,
        gateway.ClientDetailsCommand(client_details_command.UpdateClientProfile(
          client_id,
          "Initrode",
          Date(2026, April, 1),
        )),
      )
      #(
        read_periods(
          conn,
          "client_profile",
          "name",
          "recorded_during",
          "client_id = " <> int.to_string(client_id),
        ),
        list.map(read_journal(conn), fn(row) { row.operation }),
      )
    })

  // Initech leftover [Jan,Apr), renamed Initrode [Apr,∞).
  assert profiles
    == [
      Period("Initech", "2024-01-01", "2026-04-01"),
      Period("Initrode", "2026-04-01", ""),
    ]
  assert journal_ops == ["update_client_profile"]
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
    pog.query("SELECT contract_id FROM contract_terms WHERE client_id = $1")
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
    pog.query("SELECT id FROM engineer_current WHERE name = $1")
    |> pog.parameter(pog.text(name))
    |> pog.returning(row_decoder)
    |> pog.execute(on: conn)
  let assert [id, ..] = returned.rows
  id
}
