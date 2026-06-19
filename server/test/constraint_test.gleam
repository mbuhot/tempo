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

/// Insert an engineer (ID-ONLY anchor) plus a founding engineer_contact row
/// carrying `name`, and return the generated id. The name now lives in the
/// contact fact (read via the engineer_current view), not on the anchor, so
/// anything reading the engineer's name still works.
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

/// Insert a client and return its generated id.
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
// (engineer, project) is rejected by the gist exclusion PK `allocation_no_overlap`.
pub fn overlapping_allocation_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let engineer_id = insert_engineer(conn, "Ada Lovelace")
        let client_id = insert_client(conn, "Babbage Ltd")
        insert_contract(conn, 9001, client_id, "2026-01-01", "2027-01-01")
        insert_project(
          conn,
          8001,
          9001,
          "Analytical Engine",
          "2026-01-01",
          "2027-01-01",
        )
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO employment (engineer_id, employed_during) VALUES "
              <> "("
              <> int.to_string(engineer_id)
              <> ", daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) VALUES "
              <> "("
              <> int.to_string(engineer_id)
              <> ", 8001, 0.50, daterange('2026-01-01','2026-06-01'))",
          )
        Nil
      },
      fn(conn) {
        // Overlaps [2026-01-01,2026-06-01) on 2026-05.
        exec(
          conn,
          "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) "
            <> "SELECT engineer_id, project_id, fraction, daterange('2026-05-01','2026-08-01') "
            <> "FROM allocation WHERE project_id = 8001",
        )
      },
    )

  assert constraint_name(error) == "allocation_no_overlap"
}

// A second engineer_contact row overlapping an existing one for the same engineer
// is rejected by the WITHOUT OVERLAPS PK `engineer_contact_no_overlap`: at most
// one contact fact may be in force per engineer per instant. (`insert_engineer`
// already opens a [2024-01-01, NULL) contact row, so any new row starting on or
// after 2024-01-01 overlaps the open tail.)
pub fn overlapping_engineer_contact_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let _engineer_id = insert_engineer(conn, "Ada Lovelace")
        Nil
      },
      fn(conn) {
        // A second contact row for the same engineer, starting inside the open
        // [2024-01-01, NULL) span the founding row already covers.
        exec(
          conn,
          "INSERT INTO engineer_contact "
            <> "(engineer_id, name, email, phone, postal_address, recorded_during) "
            <> "SELECT engineer_id, name, email, phone, postal_address, "
            <> "daterange('2025-01-01', NULL, '[)') "
            <> "FROM engineer_contact WHERE name = 'Ada Lovelace'",
        )
      },
    )

  assert constraint_name(error) == "engineer_contact_no_overlap"
}

// A second client_profile row overlapping an existing one for the same client is
// rejected by the WITHOUT OVERLAPS PK `client_profile_no_overlap`: at most one
// profile fact may be in force per client per instant. (`insert_client` already
// opens a [2024-01-01, NULL) profile row, so any new row starting on or after
// 2024-01-01 overlaps the open tail.)
pub fn overlapping_client_profile_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let _client_id = insert_client(conn, "Babbage Ltd")
        Nil
      },
      fn(conn) {
        // A second profile row for the same client, starting inside the open
        // [2024-01-01, NULL) span the founding row already covers.
        exec(
          conn,
          "INSERT INTO client_profile "
            <> "(client_id, name, recorded_during) "
            <> "SELECT client_id, name, daterange('2025-01-01', NULL, '[)') "
            <> "FROM client_profile WHERE name = 'Babbage Ltd'",
        )
      },
    )

  assert constraint_name(error) == "client_profile_no_overlap"
}

// --- PERIOD foreign keys: the containment chain (PRD FR-5) ------------------

// An allocation whose period runs past the engineer's employment is rejected by
// the PERIOD FK `allocation_within_employment`: employment ends, so the
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

  assert constraint_name(error) == "allocation_within_employment"
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
        // applied before `gleam test` in CI) cannot trigger a leave_no_overlap
        // conflict before the intended PERIOD-FK violation.
        exec(
          conn,
          "INSERT INTO leave (engineer_id, kind, on_leave_during) "
            <> "SELECT employment.engineer_id, 'annual', daterange('2026-05-01','2026-07-01') "
            <> "FROM employment JOIN engineer_current engineer ON engineer.id = employment.engineer_id "
            <> "WHERE engineer.name = 'Katherine Johnson'",
        )
      },
    )

  assert constraint_name(error) == "leave_within_employment"
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
        // applied before `gleam test` in CI) cannot trigger an engineer_role_no_overlap
        // conflict before the intended PERIOD-FK violation.
        exec(
          conn,
          "INSERT INTO engineer_role (engineer_id, level, held_during) "
            <> "SELECT employment.engineer_id, 5, daterange('2026-01-01','2026-08-01') "
            <> "FROM employment JOIN engineer_current engineer ON engineer.id = employment.engineer_id "
            <> "WHERE engineer.name = 'Margaret Hamilton'",
        )
      },
    )

  assert constraint_name(error) == "engineer_role_within_employment"
}

// An allocation whose period runs past the project's run is rejected by the
// PERIOD FK `allocation_within_project` (allocation ⊂ project).
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

  assert constraint_name(error) == "allocation_within_project"
}

// A project whose period runs past its contract's term is rejected by the
// PERIOD FK `project_within_contract` (project ⊂ contract).
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

  assert constraint_name(error) == "project_within_contract"
}

// A timesheet day not covered by an allocation is rejected by the PERIOD FK
// `timesheet_within_allocation` (PRD FR-5: cannot log against a project you are
// not allocated to that day).
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

  assert constraint_name(error) == "timesheet_within_allocation"
}

// --- Financial cross-references (013) ---------------------------------------

// An invoice whose billing month falls outside the project's active period is
// rejected by the PERIOD FK `invoice_within_project` (invoice's month ⊂ project).
// A plain FK is impossible (project's PK is composite, so `id` is not unique); the
// temporal FK keys against project's temporal PK instead.
pub fn invoice_outside_project_active_period_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let client_id = insert_client(conn, "Xanadu")
        insert_contract(conn, 9006, client_id, "2026-01-01", "2027-01-01")
        insert_project(
          conn,
          8006,
          9006,
          "Hypertext",
          "2026-01-01",
          "2027-01-01",
        )
        Nil
      },
      fn(conn) {
        // Bill a 2025 month, before the project was active.
        exec(
          conn,
          "INSERT INTO invoice (project_id, billing_period) VALUES "
            <> "(8006, daterange('2025-06-01','2025-07-01'))",
        )
      },
    )

  assert constraint_name(error) == "invoice_within_project"
}

// An invoice_line referencing a non-existent engineer is rejected by the plain FK
// `invoice_line_engineer_fkey` (the snapshot ledger stays self-consistent).
pub fn invoice_line_for_unknown_engineer_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let client_id = insert_client(conn, "Aperture")
        insert_contract(conn, 9007, client_id, "2026-01-01", "2027-01-01")
        insert_project(conn, 8007, 9007, "Portal", "2026-01-01", "2027-01-01")
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO invoice (project_id, billing_period) VALUES "
              <> "(8007, daterange('2026-06-01','2026-07-01'))",
          )
        Nil
      },
      fn(conn) {
        // engineer 999999 does not exist.
        exec(
          conn,
          "INSERT INTO invoice_line (invoice_id, engineer_id, level, day_rate, days, amount) "
            <> "SELECT id, 999999, 1, 800, 1, 800 FROM invoice WHERE project_id = 8007",
        )
      },
    )

  assert constraint_name(error) == "invoice_line_engineer_fkey"
}

// A payroll_line referencing a non-existent engineer is rejected by the plain FK
// `payroll_line_engineer_fkey`.
pub fn payroll_line_for_unknown_engineer_is_rejected_test() {
  let error =
    reject(
      fn(conn) {
        let assert Ok(_) =
          exec(
            conn,
            "INSERT INTO payroll_run (period) VALUES "
              <> "(daterange('2099-01-01','2099-02-01'))",
          )
        Nil
      },
      fn(conn) {
        exec(
          conn,
          "INSERT INTO payroll_line (run_id, engineer_id, amount, days) "
            <> "SELECT id, 999999, 100, 1 FROM payroll_run "
            <> "WHERE period = daterange('2099-01-01','2099-02-01')",
        )
      },
    )

  assert constraint_name(error) == "payroll_line_engineer_fkey"
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
            "INSERT INTO rate_card (level, day_rate, effective_during) VALUES "
              <> "(7, 1200.00, daterange('2026-01-01','2027-01-01'))",
          )
        let assert Ok(_) =
          exec(
            conn,
            "UPDATE rate_card FOR PORTION OF effective_during "
              <> "FROM '2026-04-01' TO '2026-08-01' "
              <> "SET day_rate = 1500.00 WHERE level = 7",
          )
        Nil
      },
      "SELECT day_rate::text, lower(effective_during)::text, upper(effective_during)::text "
        <> "FROM rate_card WHERE level = 7 ORDER BY lower(effective_during)",
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
// the coalescing the v2-split migration relies on (unnest(range_agg(allocated_during))).
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

/// Mint a contract: its id-only anchor + a contract_terms row over [from, to).
/// Contract and project are now anchor + facts, so the term (and its client_id)
/// live in contract_terms; project_within_contract follows the rename and still
/// targets contract_terms(contract_id, term).
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
      "INSERT INTO contract (id) VALUES (" <> int.to_string(contract_id) <> ")",
    )
  let assert Ok(_) =
    exec(
      conn,
      "INSERT INTO contract_terms (contract_id, client_id, term) VALUES ("
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

/// Mint a project: its id-only anchor + a project_run row (the existence/contract
/// window, target of the allocation/invoice PERIOD FKs) + a project_profile row
/// carrying the NAME as `title` so name reads through project_current still work.
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

/// Insert a project (anchor + run + profile), returning pog's `Result` for the
/// project_run insert so a PERIOD-FK violation against the contract can be
/// surfaced. The anchor and profile are inserted first (they cannot violate the
/// PERIOD FK); the run insert is the one whose Result is returned.
fn try_insert_project(
  conn: pog.Connection,
  project_id: Int,
  contract_id: Int,
  name: String,
  valid_from: String,
  valid_to: String,
) -> Result(Nil, pog.QueryError) {
  let assert Ok(_) =
    exec(
      conn,
      "INSERT INTO project (id) VALUES (" <> int.to_string(project_id) <> ")",
    )
  let assert Ok(_) =
    exec(
      conn,
      "INSERT INTO project_profile (project_id, title, summary, recorded_during) VALUES ("
        <> int.to_string(project_id)
        <> ", '"
        <> name
        <> "', '', daterange('2024-01-01', NULL, '[)'))",
    )
  exec(
    conn,
    "INSERT INTO project_run (project_id, contract_id, active_during) VALUES ("
      <> int.to_string(project_id)
      <> ", "
      <> int.to_string(contract_id)
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
      "INSERT INTO employment (engineer_id, employed_during) VALUES ("
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
    "INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during) "
      <> "SELECT employment.engineer_id, "
      <> int.to_string(project_id)
      <> ", 0.50, daterange('"
      <> valid_from
      <> "','"
      <> valid_to
      <> "') "
      <> "FROM employment JOIN engineer_current engineer ON engineer.id = employment.engineer_id "
      <> "WHERE engineer.name = '"
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
