//// Layer-1 temporal-constraint tests (ARCHITECTURE.md §10.1, PRD FR-5).
////
//// These prove the **database**, not the application, enforces every temporal
//// rule: WITHOUT OVERLAPS exclusion, the PERIOD-FK containment chain,
//// FOR PORTION OF splitting, and range_agg coalescing.
////
//// Every test runs its fixtures inside a single `pog.transaction` that is
//// always rolled back, so the suite leaves no residue that could disturb the
//// seed (P2-T03). Two patterns are used:
////
////   * Rejection tests deliberately attempt the violating statement; the
////     callback returns `Error(query_error)` so the transaction rolls back and
////     `pog.transaction` hands the `QueryError` back via `TransactionRolledBack`.
////   * Result tests (FOR PORTION OF, range_agg) run the operation, read the
////     resulting rows, then return `Error(rows)` to roll the fixture back while
////     smuggling the read rows out through `TransactionRolledBack`.
////
//// Fixtures are small and explicit (not the full seed). Identity ids are
//// captured via `RETURNING id`; fact-table ids (contract/project) use high,
//// test-local literals well clear of any seed range.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import pog
import tempo/server/context

// --- fixtures ---------------------------------------------------------------

/// Insert an engineer and return its generated id.
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

/// Insert a client and return its generated id.
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

/// Run a parameterless statement, returning pog's `Result` so a violating
/// statement's `QueryError` can be surfaced to the assertion.
fn exec(conn: pog.Connection, sql: String) -> Result(Nil, pog.QueryError) {
  pog.query(sql)
  |> pog.execute(on: conn)
  |> result_replace_nil
}

fn result_replace_nil(
  result: Result(pog.Returned(Nil), pog.QueryError),
) -> Result(Nil, pog.QueryError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Run `setup` (asserted to succeed) then attempt `violation`, returning the
/// `QueryError` the database raised. The whole transaction is rolled back so no
/// fixture rows survive. Panics if the violation unexpectedly succeeds.
fn reject(
  setup: fn(pog.Connection) -> Nil,
  violation: fn(pog.Connection) -> Result(Nil, pog.QueryError),
) -> pog.QueryError {
  let outcome =
    pog.transaction(context_db(), fn(conn) {
      setup(conn)
      case violation(conn) {
        // The violating statement was rejected: carry the error out as the
        // transaction's Error so pog rolls everything back.
        Error(query_error) -> Error(query_error)
        // It unexpectedly succeeded: still roll back, but signal the surprise.
        Ok(Nil) -> Error(unexpected_success())
      }
    })
  let assert Error(pog.TransactionRolledBack(query_error)) = outcome
  query_error
}

fn unexpected_success() -> pog.QueryError {
  pog.PostgresqlError(
    code: "TEST",
    name: "violation_unexpectedly_succeeded",
    message: "the statement under test was expected to be rejected",
  )
}

/// A small connection pool for a single test. Each test manages its own
/// rollback so one connection suffices; keeping the pool tiny avoids exhausting
/// PG's `max_connections` across the suite (which otherwise surfaces as decode
/// timeouts under gleeunit's concurrent runner).
fn context_db() -> pog.Connection {
  let pool_name = process.new_name(prefix: "tempo_constraint_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  started.data
}

// --- WITHOUT OVERLAPS -------------------------------------------------------

// A second allocation overlapping an existing one for the same
// (engineer, project) is rejected by the gist exclusion PK `allocation_pkey`.
pub fn overlapping_allocation_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Ada Lovelace")
        let client_id = insert_client(conn, "Babbage Ltd")
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO contract (id, client_id, valid_at) VALUES "
              <> "(9001, "
              <> int.to_string(client_id)
              <> ", daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO project (id, contract_id, name, valid_at) VALUES "
              <> "(8001, 9001, 'Analytical Engine', daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO employment (engineer_id, valid_at) VALUES "
              <> "("
              <> int.to_string(engineer_id)
              <> ", daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO allocation (engineer_id, project_id, fraction, day_rate, valid_at) VALUES "
              <> "("
              <> int.to_string(engineer_id)
              <> ", 8001, 0.50, 1000.00, daterange('2026-01-01','2026-06-01'))",
          )
        Nil
      },
      fn(conn) {
        // Overlaps [2026-01-01,2026-06-01) on 2026-05.
        exec(
          conn,
          "INSERT INTO allocation (engineer_id, project_id, fraction, day_rate, valid_at) "
            <> "SELECT engineer_id, project_id, fraction, day_rate, daterange('2026-05-01','2026-08-01') "
            <> "FROM allocation WHERE project_id = 8001",
        )
      },
    )

  assert constraint_name(error) == "allocation_pkey"
}

// --- PERIOD foreign keys: the containment chain (PRD FR-5) ------------------

// An allocation whose period runs past the engineer's employment is rejected by
// the PERIOD FK `allocation_engineer_id_valid_at_fkey`: employment ends, so the
// association cannot dangle beyond it.
pub fn allocation_past_employment_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Grace Hopper")
        let client_id = insert_client(conn, "Navy Yard")
        insert_contract(conn, 9002, client_id, "2026-01-01", "2027-01-01")
        insert_project(conn, 8002, 9002, "COBOL", "2026-01-01", "2027-01-01")
        // Employment ends 2026-06-01.
        insert_employment(conn, engineer_id, "2026-01-01", "2026-06-01")
        Nil
      },
      fn(conn) {
        // Allocation runs to 2026-08-01, past employment's 2026-06-01 end.
        insert_allocation_for(
          conn,
          "Grace Hopper",
          8002,
          "2026-01-01",
          "2026-08-01",
        )
      },
    )

  assert constraint_name(error) == "allocation_engineer_id_valid_at_fkey"
}

// Leave that extends past employment is rejected by the PERIOD FK on `leave`.
pub fn leave_past_employment_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Katherine Johnson")
        insert_employment(conn, engineer_id, "2026-01-01", "2026-06-01")
        Nil
      },
      fn(conn) {
        // Leave 2026-05..2026-07 outlives employment (ends 2026-06-01). Scoped
        // by the fixture engineer's name so seeded employment rows (003_seed.sql,
        // applied before `gleam test` in CI) cannot trigger a leave_pkey
        // conflict before the intended PERIOD-FK violation.
        exec(
          conn,
          "INSERT INTO leave (engineer_id, kind, valid_at) "
            <> "SELECT emp.engineer_id, 'annual', daterange('2026-05-01','2026-07-01') "
            <> "FROM employment emp JOIN engineer e ON e.id = emp.engineer_id "
            <> "WHERE e.name = 'Katherine Johnson'",
        )
      },
    )

  assert constraint_name(error) == "leave_engineer_id_valid_at_fkey"
}

// A role (level) period extending past employment is rejected by the PERIOD FK
// on `engineer_role`.
pub fn role_past_employment_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Margaret Hamilton")
        insert_employment(conn, engineer_id, "2026-01-01", "2026-06-01")
        Nil
      },
      fn(conn) {
        // Role 2026-01..2026-08 outlives employment (ends 2026-06-01). Scoped by
        // the fixture engineer's name so seeded employment rows (003_seed.sql,
        // applied before `gleam test` in CI) cannot trigger an engineer_role_pkey
        // conflict before the intended PERIOD-FK violation.
        exec(
          conn,
          "INSERT INTO engineer_role (engineer_id, level, valid_at) "
            <> "SELECT emp.engineer_id, 5, daterange('2026-01-01','2026-08-01') "
            <> "FROM employment emp JOIN engineer e ON e.id = emp.engineer_id "
            <> "WHERE e.name = 'Margaret Hamilton'",
        )
      },
    )

  assert constraint_name(error) == "engineer_role_engineer_id_valid_at_fkey"
}

// An allocation whose period runs past the project's run is rejected by the
// PERIOD FK `allocation_project_id_valid_at_fkey` (allocation ⊂ project).
pub fn allocation_outside_project_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Barbara Liskov")
        let client_id = insert_client(conn, "MIT")
        insert_contract(conn, 9003, client_id, "2026-01-01", "2027-01-01")
        // Project runs only to 2026-06-01.
        insert_project(conn, 8003, 9003, "CLU", "2026-01-01", "2026-06-01")
        // Employment spans the whole period so only the project FK can fail.
        insert_employment(conn, engineer_id, "2026-01-01", "2027-01-01")
        Nil
      },
      fn(conn) {
        // Allocation runs to 2026-08-01, past the project's 2026-06-01 end.
        insert_allocation_for(
          conn,
          "Barbara Liskov",
          8003,
          "2026-01-01",
          "2026-08-01",
        )
      },
    )

  assert constraint_name(error) == "allocation_project_id_valid_at_fkey"
}

// A project whose period runs past its contract's term is rejected by the
// PERIOD FK `project_contract_id_valid_at_fkey` (project ⊂ contract).
pub fn project_outside_contract_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let client_id = insert_client(conn, "Bell Labs")
        // Contract ends 2026-06-01.
        insert_contract(conn, 9004, client_id, "2026-01-01", "2026-06-01")
        Nil
      },
      fn(conn) {
        // Project runs to 2026-08-01, past the contract's 2026-06-01 end.
        try_insert_project(conn, 8004, 9004, "Unix", "2026-01-01", "2026-08-01")
      },
    )

  assert constraint_name(error) == "project_contract_id_valid_at_fkey"
}

// A timesheet day not covered by an allocation is rejected by the PERIOD FK
// `timesheet_engineer_id_project_id_work_day_fkey` (PRD FR-5: cannot log against
// a project you are not allocated to that day).
pub fn timesheet_without_allocation_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Radia Perlman")
        let client_id = insert_client(conn, "DEC")
        insert_contract(conn, 9005, client_id, "2026-01-01", "2027-01-01")
        insert_project(
          conn,
          8005,
          9005,
          "Spanning Tree",
          "2026-01-01",
          "2027-01-01",
        )
        insert_employment(conn, engineer_id, "2026-01-01", "2027-01-01")
        // Allocated only during January 2026.
        let assert Ok(_) =
          insert_allocation_for(
            conn,
            "Radia Perlman",
            8005,
            "2026-01-01",
            "2026-02-01",
          )
        Nil
      },
      fn(conn) {
        // Log a day in March, outside the January allocation.
        exec(
          conn,
          "INSERT INTO timesheet (engineer_id, project_id, work_day, hours) "
            <> "SELECT engineer_id, project_id, daterange('2026-03-15','2026-03-16'), 8.00 "
            <> "FROM allocation WHERE project_id = 8005",
        )
      },
    )

  assert constraint_name(error)
    == "timesheet_engineer_id_project_id_work_day_fkey"
}

// --- FOR PORTION OF: surgical rate edits (PRD FR-6) -------------------------

/// One rate-card sub-period row, rendered as plain text for exact assertions:
/// `(day_rate, valid_from, valid_to)`.
type RatePeriod {
  RatePeriod(day_rate: String, valid_from: String, valid_to: String)
}

// Updating the middle of a single rate_card period via FOR PORTION OF splits it
// into three rows: the unchanged before/after carve-offs plus the bumped middle.
// (P1-T03 finding: PG reports "UPDATE 1" despite producing extra rows; never
// rely on the affected-row count — read the rows back instead.)
pub fn for_portion_of_splits_rate_card_test() {
  // Uses level 7, which the seed (003_seed.sql) leaves unused — the seed
  // populates L3–L6 and the CI runner applies it before `gleam test`, so a
  // seeded level would collide with rate_card's WITHOUT OVERLAPS PK.
  let rows =
    read_rolling_back(
      fn(conn) {
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO rate_card (level, day_rate, valid_at) VALUES "
              <> "(7, 1200.00, daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "UPDATE rate_card FOR PORTION OF valid_at "
              <> "FROM '2026-04-01' TO '2026-08-01' "
              <> "SET day_rate = 1500.00 WHERE level = 7",
          )
        Nil
      },
      "SELECT day_rate::text, lower(valid_at)::text, upper(valid_at)::text "
        <> "FROM rate_card WHERE level = 7 ORDER BY lower(valid_at)",
      rate_period_decoder(),
    )

  assert rows
    == [
      RatePeriod("1200.00", "2026-01-01", "2026-04-01"),
      RatePeriod("1500.00", "2026-04-01", "2026-08-01"),
      RatePeriod("1200.00", "2026-08-01", "2027-01-01"),
    ]
}

fn rate_period_decoder() -> decode.Decoder(RatePeriod) {
  use day_rate <- decode.field(0, decode.string)
  use valid_from <- decode.field(1, decode.string)
  use valid_to <- decode.field(2, decode.string)
  decode.success(RatePeriod(day_rate:, valid_from:, valid_to:))
}

// --- range_agg coalescing (ARCHITECTURE.md §7; the v2-split migration) -------

/// One coalesced segment, rendered as text: `(valid_from, valid_to)`.
type Segment {
  Segment(valid_from: String, valid_to: String)
}

// range_agg merges adjacent and overlapping periods into one segment while
// preserving a genuine gap. Here [Jan,Feb)+[Feb,Mar) are adjacent and
// [Feb-15,Apr) overlaps them, so all three collapse to [Jan,Apr); the separate
// [May,Jun) stays its own segment because Apr–May is a real gap. This is exactly
// the coalescing the v2-split migration relies on (unnest(range_agg(valid_at))).
pub fn range_agg_coalesces_and_preserves_gap_test() {
  let rows =
    read_rolling_back(
      fn(_conn) { Nil },
      "SELECT lower(seg)::text, upper(seg)::text FROM ("
        <> "SELECT unnest(range_agg(r)) AS seg FROM (VALUES "
        <> "(daterange('2026-01-01','2026-02-01')), "
        <> "(daterange('2026-02-01','2026-03-01')), "
        <> "(daterange('2026-02-15','2026-04-01')), "
        <> "(daterange('2026-05-01','2026-06-01'))"
        <> ") v(r)) parts ORDER BY lower(seg)",
      segment_decoder(),
    )

  assert rows
    == [
      Segment("2026-01-01", "2026-04-01"),
      Segment("2026-05-01", "2026-06-01"),
    ]
}

fn segment_decoder() -> decode.Decoder(Segment) {
  use valid_from <- decode.field(0, decode.string)
  use valid_to <- decode.field(1, decode.string)
  decode.success(Segment(valid_from:, valid_to:))
}

/// Run `setup` (asserted to succeed), then run the read `query`, decode its rows
/// with `row_decoder`, and roll the whole transaction back — smuggling the rows
/// out through `TransactionRolledBack` so no fixture survives.
fn read_rolling_back(
  setup: fn(pog.Connection) -> Nil,
  query: String,
  row_decoder: decode.Decoder(row),
) -> List(row) {
  let outcome =
    pog.transaction(context_db(), fn(conn) {
      setup(conn)
      let assert Ok(returned) =
        pog.query(query)
        |> pog.returning(row_decoder)
        |> pog.execute(on: conn)
      // Returning Error rolls the fixture back while carrying the rows out.
      Error(returned.rows)
    })
  let assert Error(pog.TransactionRolledBack(rows)) = outcome
  rows
}

// --- additional fixture builders --------------------------------------------

fn insert_contract(
  conn: pog.Connection,
  contract_id: Int,
  client_id: Int,
  valid_from: String,
  valid_to: String,
) -> Nil {
  let assert Ok(_) =
    exec(
      conn,
      "INSERT INTO contract (id, client_id, valid_at) VALUES ("
        <> int.to_string(contract_id)
        <> ", "
        <> int.to_string(client_id)
        <> ", daterange('"
        <> valid_from
        <> "','"
        <> valid_to
        <> "'))",
    )
  Nil
}

fn insert_project(
  conn: pog.Connection,
  project_id: Int,
  contract_id: Int,
  name: String,
  valid_from: String,
  valid_to: String,
) -> Nil {
  let assert Ok(_) =
    try_insert_project(
      conn,
      project_id,
      contract_id,
      name,
      valid_from,
      valid_to,
    )
  Nil
}

/// Insert a project, returning pog's `Result` so a PERIOD-FK violation against
/// the contract can be surfaced.
fn try_insert_project(
  conn: pog.Connection,
  project_id: Int,
  contract_id: Int,
  name: String,
  valid_from: String,
  valid_to: String,
) -> Result(Nil, pog.QueryError) {
  exec(
    conn,
    "INSERT INTO project (id, contract_id, name, valid_at) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(contract_id)
      <> ", '"
      <> name
      <> "'"
      <> ", daterange('"
      <> valid_from
      <> "','"
      <> valid_to
      <> "'))",
  )
}

fn insert_employment(
  conn: pog.Connection,
  engineer_id: Int,
  valid_from: String,
  valid_to: String,
) -> Nil {
  let assert Ok(_) =
    exec(
      conn,
      "INSERT INTO employment (engineer_id, valid_at) VALUES ("
        <> int.to_string(engineer_id)
        <> ", daterange('"
        <> valid_from
        <> "','"
        <> valid_to
        <> "'))",
    )
  Nil
}

/// Insert an allocation for the named fixture engineer onto `project_id`,
/// reading the engineer id back from the `employment` fixture row so callers do
/// not have to thread it through. Scoped by engineer name so seeded employment
/// rows (003_seed.sql, applied before `gleam test` in CI) are never picked up.
/// Returns pog's `Result` so a PERIOD-FK violation can be surfaced.
fn insert_allocation_for(
  conn: pog.Connection,
  engineer_name: String,
  project_id: Int,
  valid_from: String,
  valid_to: String,
) -> Result(Nil, pog.QueryError) {
  exec(
    conn,
    "INSERT INTO allocation (engineer_id, project_id, fraction, day_rate, valid_at) "
      <> "SELECT emp.engineer_id, "
      <> int.to_string(project_id)
      <> ", 0.50, 1000.00, daterange('"
      <> valid_from
      <> "','"
      <> valid_to
      <> "') "
      <> "FROM employment emp JOIN engineer e ON e.id = emp.engineer_id "
      <> "WHERE e.name = '"
      <> engineer_name
      <> "'",
  )
}

// --- helpers used by assertions ---------------------------------------------

/// The constraint name pog reports for a violation, normalised across the two
/// shapes PG uses (exclusion/unique come back as `ConstraintViolated`, FK
/// violations as `PostgresqlError` whose message names the constraint).
fn constraint_name(error: pog.QueryError) -> String {
  case error {
    pog.ConstraintViolated(constraint:, ..) -> constraint
    pog.PostgresqlError(message:, ..) -> extract_constraint(message)
    _ -> "unexpected:" <> describe_error(error)
  }
}

/// FK violations arrive as PostgresqlError; pull the quoted constraint name out
/// of `... violates foreign key constraint "<name>"`.
fn extract_constraint(message: String) -> String {
  case list.last(string.split(message, "constraint \"")) {
    Ok(tail) ->
      case list.first(string.split(tail, "\"")) {
        Ok(name) -> name
        Error(Nil) -> message
      }
    Error(Nil) -> message
  }
}

fn describe_error(error: pog.QueryError) -> String {
  case error {
    pog.QueryTimeout -> "QueryTimeout"
    pog.ConnectionUnavailable -> "ConnectionUnavailable"
    _ -> "other"
  }
}
