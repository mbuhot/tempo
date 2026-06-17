//// Domain: the payroll aggregate — a per-month run whose lines are the prorated
//// salary owed each employed engineer. `handle` matches the payroll commands, does
//// ONLY their temporal writes on the in-transaction connection, classifies any
//// database rejection, and returns the journal event(s) it produced;
//// `command.dispatch` owns the transaction and persists those events. No HTTP —
//// never imports `wisp`.
////
//// `RunPayroll` is an Assert that also computes its lines: mint the run identity,
//// compute one prorated amount per employed engineer (`payroll_amounts` integrates
//// `monthly_salary[level]` over `employment ∩ role-version ∩ salary-version ∩ month`,
//// so a mid-month hire/termination is clipped, a promotion blends two salaries, and
//// leave is paid in full — FR-F5/F6), then snapshot one `payroll_line` per engineer.

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, RunPayroll}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a payroll-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection, and on success
/// return the single journal event it produced. Only the payroll commands reach
/// here (the dispatch `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    RunPayroll(period_from:, period_to:) ->
      run_payroll(conn, period_from, period_to)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// Run payroll for a month: mint the run identity, compute the prorated amount per
/// employed engineer for the period, and insert each as a `payroll_line` — all
/// threaded through the minted run id.
fn run_payroll(
  conn: pog.Connection,
  period_from: Date,
  period_to: Date,
) -> Result(Nil, pog.QueryError) {
  use created <- result.try(sql.payroll_run_create(conn, period_from, period_to))
  let run_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  use amounts <- result.try(sql.payroll_amounts(conn, period_from, period_to))
  insert_lines(conn, run_id, amounts.rows)
}

/// Insert each computed payroll amount as a line for the run, in order. Each line
/// carries the engineer, the prorated amount owed, and the employed days it covers
/// (all from `payroll_amounts`).
fn insert_lines(
  conn: pog.Connection,
  run_id: Int,
  amounts: List(sql.PayrollAmountsRow),
) -> Result(Nil, pog.QueryError) {
  case amounts {
    [] -> Ok(Nil)
    [amount, ..rest] -> {
      use _ <- result.try(sql.payroll_line_insert(
        conn,
        run_id,
        amount.engineer_id,
        amount.amount,
        amount.days,
      ))
      insert_lines(conn, run_id, rest)
    }
  }
}

/// The journal event(s) an applied payroll command produces.
fn events(command: Command) -> List(Event) {
  case command {
    RunPayroll(period_from:, period_to:) -> [
      Event(
        operation: "run_payroll",
        summary: "Run payroll over " <> operation.span(period_from, period_to),
        payload: codecs.encode_command(command),
      ),
    ]
    _ -> []
  }
}
