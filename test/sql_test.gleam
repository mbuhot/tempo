//// Layer-3 as-of query tests (ARCHITECTURE.md §10.3) against the generated
//// Squirrel functions in `tempo/server/sql`. They run the deterministic v1-wide
//// seed (003_seed.sql, "now" = 2026-06-15) at fixed dates and assert the exact
//// rows, proving the temporal joins and the range-decomposition boundary
//// (ADR-011) end to end.
////
//// Read-only queries (board, leave, timesheet form) run directly against the
//// seeded DB. The write path and the FOR PORTION OF edit mutate, so they run
//// inside a `pog.transaction` that is always rolled back (the same smuggle-rows-
//// out-via-Error pattern as constraint_test) so the shared seed is undisturbed.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{Some}
import gleam/time/calendar.{April, August, Date, January, July, June, March}
import pog
import tempo/server/context
import tempo/server/sql

// --- connection -------------------------------------------------------------

/// A single-connection pool per test. Each mutating test rolls back its own
/// transaction; the read-only tests touch only the seed. A tiny pool avoids
/// exhausting PG's max_connections across the concurrent gleeunit runner.
fn db() -> pog.Connection {
  let pool_name = process.new_name(prefix: "tempo_sql_test_db")
  let config =
    context.pool_config(context.settings_from_env(), pool_name)
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  started.data
}

// --- board_as_of (PRD FR-1, FR-2, FR-3, FR-4) -------------------------------

// Scrub into the past (2025-03-01, PRD FR-2): history with no audit tables.
// Inventory Sync (project 200) does not start until 2025-06-01, so Priya is on
// only Ledger Migration at L5 (rate 1200, pre-bump); Marcus is full-time on Data
// Platform at L4 (rate 1000, pre-promotion); Aisha is present at L6 (her leave is
// over a year away). A meaningfully different board from the seed "now".
pub fn board_as_of_past_test() {
  let assert Ok(returned) = sql.board_as_of(db(), Date(2025, March, 1))

  assert returned.rows
    == [
      sql.BoardAsOfRow(
        engineer: "Aisha Okafor",
        level: 6,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1800.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Marcus Chen",
        level: 4,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1000.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Ledger Migration",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1200.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2027, January, 1),
      ),
    ]
}

// As of the seed "now" (2026-06-15): Priya is on both half-time projects at L5
// (rate 1200, pre-bump); Marcus is full-time on Data Platform at L4 (rate 1000,
// pre-promotion); Aisha is suppressed because she is on leave across this date.
pub fn board_as_of_now_test() {
  let assert Ok(returned) = sql.board_as_of(db(), Date(2026, June, 15))

  assert returned.rows
    == [
      sql.BoardAsOfRow(
        engineer: "Marcus Chen",
        level: 4,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1000.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Inventory Sync",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1200.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Ledger Migration",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1200.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2027, January, 1),
      ),
    ]
}

// Scrub into the future past 2026-07-01: Marcus's seeded promotion (L4 -> L5)
// and the L5 rate-card bump (1200 -> 1400) both activate unaided (PRD FR-3), and
// Aisha's leave has ended so she reappears on the board, full-time at L6.
pub fn board_as_of_future_test() {
  let assert Ok(returned) = sql.board_as_of(db(), Date(2026, August, 1))

  assert returned.rows
    == [
      sql.BoardAsOfRow(
        engineer: "Aisha Okafor",
        level: 6,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1800.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Marcus Chen",
        level: 5,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1400.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Inventory Sync",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1400.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardAsOfRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Ledger Migration",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1400.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2027, January, 1),
      ),
    ]
}

// --- board_leave_as_of (PRD FR-4) -------------------------------------------

// As of the seed "now", exactly Aisha is on leave: the row the board renders as
// "On leave: annual", carrying her level and the leave period's bounds.
pub fn board_leave_as_of_now_test() {
  let assert Ok(returned) = sql.board_leave_as_of(db(), Date(2026, June, 15))

  assert returned.rows
    == [
      sql.BoardLeaveAsOfRow(
        engineer: "Aisha Okafor",
        level: Some(6),
        kind: "annual",
        valid_from: Date(2026, June, 8),
        valid_to: Date(2026, June, 22),
      ),
    ]
}

// Once the leave window has passed, nobody is on leave.
pub fn board_leave_as_of_after_leave_is_empty_test() {
  let assert Ok(returned) = sql.board_leave_as_of(db(), Date(2026, August, 1))

  assert returned.rows == []
}

// --- timesheet_form (PRD FR-7) ----------------------------------------------

// Priya (id 1) on Tuesday 2026-06-09: her two half-time projects, each with the
// 4.00 hours seeded for that day.
pub fn timesheet_form_with_logged_hours_test() {
  let assert Ok(returned) = sql.timesheet_form(db(), 1, Date(2026, June, 9))

  assert returned.rows
    == [
      sql.TimesheetFormRow(
        project_id: 200,
        project: "Inventory Sync",
        fraction: 0.5,
        hours: 4.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.TimesheetFormRow(
        project_id: 100,
        project: "Ledger Migration",
        fraction: 0.5,
        hours: 4.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2027, January, 1),
      ),
    ]
}

// A day with no logged hours yet: same projects, hours COALESCEd to 0.
pub fn timesheet_form_unlogged_day_test() {
  let assert Ok(returned) = sql.timesheet_form(db(), 1, Date(2026, June, 10))

  assert returned.rows
    == [
      sql.TimesheetFormRow(
        project_id: 200,
        project: "Inventory Sync",
        fraction: 0.5,
        hours: 0.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.TimesheetFormRow(
        project_id: 100,
        project: "Ledger Migration",
        fraction: 0.5,
        hours: 0.0,
        valid_from: Date(2024, January, 1),
        valid_to: Date(2027, January, 1),
      ),
    ]
}

// Aisha (id 3) is on leave on the seed "now", so her timesheet form is empty —
// the form offers no projects on a leave day (PRD FR-4/FR-5).
pub fn timesheet_form_on_leave_is_empty_test() {
  let assert Ok(returned) = sql.timesheet_form(db(), 3, Date(2026, June, 15))

  assert returned.rows == []
}

// --- timesheet write: delete-then-insert (P1-T04) ---------------------------

/// Hours for one project, read back as text via the form query inside the same
/// rolled-back transaction.
type Logged {
  Logged(hours: Float)
}

// First entry: timesheet_delete (no-op) then timesheet_write inserts the row.
// Re-running with new hours replaces it (delete 1, insert 1) — exactly one row,
// the new value. The whole fixture is rolled back so the seed is untouched.
pub fn timesheet_write_is_an_upsert_test() {
  // Marcus (id 2) on project 300 on 2026-06-10 has no seeded entry.
  let day = Date(2026, June, 10)
  let hours_after =
    run_rolling_back(fn(conn) {
      let assert Ok(_) = sql.timesheet_delete(conn, 2, 300, day)
      let assert Ok(_) = sql.timesheet_write(conn, 2, 300, day, 6.0)
      // Re-entry with a corrected value, same code path.
      let assert Ok(_) = sql.timesheet_delete(conn, 2, 300, day)
      let assert Ok(_) = sql.timesheet_write(conn, 2, 300, day, 8.0)
      let assert Ok(form) = sql.timesheet_form(conn, 2, day)
      case form.rows {
        [row, ..] -> [Logged(hours: row.hours)]
        [] -> []
      }
    })

  assert hours_after == [Logged(hours: 8.0)]
}

// --- rate_card_for_portion_of (PRD FR-6) ------------------------------------

/// One rate-card sub-period as plain text, for exact assertions.
type RatePeriod {
  RatePeriod(day_rate: String, valid_from: String, valid_to: String)
}

// Bumping L4's rate for [2026-04-01, 2026-08-01) splits its single 2024..2027
// period (seeded at 1000.00) into three rows: unchanged 1000 before, the bumped
// 950 middle, unchanged 1000 after. PG reports UPDATE 1 despite the split
// (P1-T03) — assert on the rows, never the affected-row count.
pub fn rate_card_for_portion_of_splits_test() {
  let rows =
    rate_rows_rolling_back(fn(conn) {
      let assert Ok(_) =
        sql.rate_card_for_portion_of(
          conn,
          Date(2026, April, 1),
          Date(2026, August, 1),
          950.0,
          4,
        )
      Nil
    })

  assert rows
    == [
      RatePeriod("1000.00", "2024-01-01", "2026-04-01"),
      RatePeriod("950.00", "2026-04-01", "2026-08-01"),
      RatePeriod("1000.00", "2026-08-01", "2027-01-01"),
    ]
}

// --- rollback helpers -------------------------------------------------------

/// Run `body` inside a transaction, then roll back, smuggling its return value
/// out through `TransactionRolledBack` so the seed is never mutated.
fn run_rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// Apply `mutate`, then read L4's rate_card rows back as text, rolling back.
fn rate_rows_rolling_back(
  mutate: fn(pog.Connection) -> Nil,
) -> List(RatePeriod) {
  let decoder = {
    use day_rate <- decode.field(0, decode.string)
    use valid_from <- decode.field(1, decode.string)
    use valid_to <- decode.field(2, decode.string)
    decode.success(RatePeriod(day_rate:, valid_from:, valid_to:))
  }
  let outcome =
    pog.transaction(db(), fn(conn) {
      mutate(conn)
      let assert Ok(returned) =
        pog.query(
          "SELECT day_rate::text, lower(valid_at)::text, upper(valid_at)::text "
          <> "FROM rate_card WHERE level = 4 ORDER BY lower(valid_at)",
        )
        |> pog.returning(decoder)
        |> pog.execute(on: conn)
      Error(returned.rows)
    })
  let assert Error(pog.TransactionRolledBack(rows)) = outcome
  rows
}
