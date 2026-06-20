//// Layer-3 query tests (ARCHITECTURE.md §10.3) against the generated
//// Squirrel functions in `tempo/server/sql`. They run the deterministic v1-wide
//// seed (002_seed.sql, "now" = 2026-06-15) at fixed dates and assert the exact
//// rows, proving the temporal joins and the range-decomposition boundary
//// (ADR-011) end to end.
////
//// Read-only queries (board, leave, timesheet form) run directly against the
//// seeded DB. The write path and the FOR PORTION OF edit mutate, so they run
//// inside a `pog.transaction` that is always rolled back (the same smuggle-rows-
//// out-via-Error pattern as constraint_test) so the shared seed is undisturbed.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/time/calendar.{April, August, Date, January, June, March, May}
import pog
import tempo/server/context
import tempo/server/sql

/// A seeded event_log id to satisfy the audit_id FK on the write fixtures below
/// (these test the SQL mechanics, not provenance). The seed always has entry 1.
const seed_audit_id = 1

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

// --- board_engaged (PRD FR-1, FR-2, FR-3, FR-4) -----------------------------

// Scrub into the past (2025-03-01, PRD FR-2): history with no audit tables.
// Inventory Sync (project 200) does not start until 2025-06-01, so Priya is on
// only Ledger Migration at L5 (rate 1200, pre-bump); Marcus is full-time on Data
// Platform at L4 (rate 1000, pre-promotion); Aisha is present at L6 (her leave is
// over a year away). A meaningfully different board from the seed "now".
pub fn board_engaged_past_test() {
  let assert Ok(returned) = sql.board_engaged(db(), Date(2025, March, 1))

  assert returned.rows
    == [
      sql.BoardEngagedRow(
        engineer: "Aisha Okafor",
        level: 6,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1800.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
        engineer: "Marcus Chen",
        level: 4,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1000.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
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

// On the seed "now" (2026-06-15): Priya is on both half-time projects at L5
// (rate 1200, pre-bump); Marcus is full-time on Data Platform at L4 (rate 1000,
// pre-promotion); Aisha is suppressed because she is on leave across this date.
pub fn board_engaged_now_test() {
  let assert Ok(returned) = sql.board_engaged(db(), Date(2026, June, 15))

  assert returned.rows
    == [
      sql.BoardEngagedRow(
        engineer: "Marcus Chen",
        level: 4,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1000.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Inventory Sync",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1200.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
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
pub fn board_engaged_future_test() {
  let assert Ok(returned) = sql.board_engaged(db(), Date(2026, August, 1))

  assert returned.rows
    == [
      sql.BoardEngagedRow(
        engineer: "Aisha Okafor",
        level: 6,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1800.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
        engineer: "Marcus Chen",
        level: 5,
        project: "Data Platform",
        client: "Globex Corporation",
        fraction: 1.0,
        day_rate: 1400.0,
        valid_from: Date(2025, January, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
        engineer: "Priya Sharma",
        level: 5,
        project: "Inventory Sync",
        client: "Northwind Trading",
        fraction: 0.5,
        day_rate: 1400.0,
        valid_from: Date(2025, June, 1),
        valid_to: Date(2027, January, 1),
      ),
      sql.BoardEngagedRow(
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

// --- board_leave (PRD FR-4) -------------------------------------------------

// On the seed "now", exactly Aisha is on leave: the row the board renders as
// "On leave: annual", carrying her level and the leave period's bounds.
pub fn board_leave_now_test() {
  let assert Ok(returned) = sql.board_leave(db(), Date(2026, June, 15))

  assert returned.rows
    == [
      sql.BoardLeaveRow(
        engineer: "Aisha Okafor",
        level: Some(6),
        kind: "annual",
        valid_from: Date(2026, June, 8),
        valid_to: Date(2026, June, 22),
      ),
    ]
}

// Once the leave window has passed, nobody is on leave.
pub fn board_leave_after_leave_is_empty_test() {
  let assert Ok(returned) = sql.board_leave(db(), Date(2026, August, 1))

  assert returned.rows == []
}

// --- timesheet_week ---------------------------------------------------------

// Priya (id 1), week of Monday 2026-06-08: her two half-time projects, each a row
// of seven cells Mon 06-08 .. Sun 06-14, ordered by project name then day. Every
// cell is allocated (both projects cover the whole week, no leave); the Tuesday
// 06-09 cell of BOTH carries the 4.00 hours the seed logged, every other day 0.
pub fn timesheet_week_with_logged_hours_test() {
  let assert Ok(returned) = sql.timesheet_week(db(), 1, Date(2026, June, 8))

  // One project's seven cells as (day, allocated, hours): allocated all seven
  // days, 4.0 only on the Tuesday 06-09 cell.
  let cells_with_tuesday_logged = [
    #(Date(2026, June, 8), True, 0.0),
    #(Date(2026, June, 9), True, 4.0),
    #(Date(2026, June, 10), True, 0.0),
    #(Date(2026, June, 11), True, 0.0),
    #(Date(2026, June, 12), True, 0.0),
    #(Date(2026, June, 13), True, 0.0),
    #(Date(2026, June, 14), True, 0.0),
  ]

  let cells_of = fn(project_id) {
    list.filter(returned.rows, fn(row) { row.project_id == project_id })
    |> list.map(fn(row) { #(row.day, row.allocated, row.hours) })
  }

  assert cells_of(200) == cells_with_tuesday_logged
  assert cells_of(100) == cells_with_tuesday_logged

  // The week is exactly these two projects, each named, in name order (Inventory
  // Sync sorts before Ledger Migration).
  assert list.map(returned.rows, fn(row) { #(row.project_id, row.project) })
    |> list.unique
    == [#(200, "Inventory Sync"), #(100, "Ledger Migration")]
}

// Priya (id 1), week of Monday 2025-05-26: Inventory Sync (200) begins on the
// Sunday 2025-06-01, so its cell is allocated ONLY on Sunday and NOT editable
// Mon..Sat — the "not yet on the project" partial-coverage case. Ledger Migration
// (100) is allocated every day of the week.
pub fn timesheet_week_partial_coverage_test() {
  let assert Ok(returned) = sql.timesheet_week(db(), 1, Date(2025, May, 26))

  // Inventory Sync: allocated only on the Sunday 2025-06-01 cell.
  let inventory_coverage =
    list.filter(returned.rows, fn(row) { row.project_id == 200 })
    |> list.map(fn(row) { #(row.day, row.allocated) })
  assert inventory_coverage
    == [
      #(Date(2025, May, 26), False),
      #(Date(2025, May, 27), False),
      #(Date(2025, May, 28), False),
      #(Date(2025, May, 29), False),
      #(Date(2025, May, 30), False),
      #(Date(2025, May, 31), False),
      #(Date(2025, June, 1), True),
    ]

  // Ledger Migration: allocated every day.
  let ledger_coverage =
    list.filter(returned.rows, fn(row) { row.project_id == 100 })
    |> list.map(fn(row) { row.allocated })
  assert ledger_coverage == [True, True, True, True, True, True, True]
}

// Aisha (id 3), week of Monday 2026-06-15: her annual leave covers the whole week
// (2026-06-08 .. 2026-06-22). She is still allocated to Data Platform across that
// span, so the query still emits its row per day — but leave takes precedence in
// the `allocated` flag, so every one of the seven cells is NOT editable. There is
// nothing she can log all week: every cell disabled.
pub fn timesheet_week_on_leave_all_cells_disabled_test() {
  let assert Ok(returned) = sql.timesheet_week(db(), 3, Date(2026, June, 15))

  let coverage =
    list.map(returned.rows, fn(row) {
      #(row.project_id, row.day, row.allocated)
    })
  assert coverage
    == [
      #(300, Date(2026, June, 15), False),
      #(300, Date(2026, June, 16), False),
      #(300, Date(2026, June, 17), False),
      #(300, Date(2026, June, 18), False),
      #(300, Date(2026, June, 19), False),
      #(300, Date(2026, June, 20), False),
      #(300, Date(2026, June, 21), False),
    ]
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
  // Marcus (id 2) on project 300 on Wednesday 2026-06-10 has no seeded entry; its
  // week begins Monday 2026-06-08.
  let day = Date(2026, June, 10)
  let week_start = Date(2026, June, 8)
  let hours_after =
    run_rolling_back(fn(conn) {
      let assert Ok(_) = sql.timesheet_delete(conn, 2, 300, day)
      let assert Ok(_) =
        sql.timesheet_write(conn, 2, 300, day, 6.0, seed_audit_id)
      // Re-entry with a corrected value, same code path.
      let assert Ok(_) = sql.timesheet_delete(conn, 2, 300, day)
      let assert Ok(_) =
        sql.timesheet_write(conn, 2, 300, day, 8.0, seed_audit_id)
      let assert Ok(week) = sql.timesheet_week(conn, 2, week_start)
      week.rows
      |> list.filter(fn(row) { row.project_id == 300 && row.day == day })
      |> list.map(fn(row) { Logged(hours: row.hours) })
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
          seed_audit_id,
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
          "SELECT day_rate::text, lower(effective_during)::text, upper(effective_during)::text "
          <> "FROM rate_card WHERE level = 4 ORDER BY lower(effective_during)",
        )
        |> pog.returning(decoder)
        |> pog.execute(on: conn)
      Error(returned.rows)
    })
  let assert Error(pog.TransactionRolledBack(rows)) = outcome
  rows
}
