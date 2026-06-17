//// Domain: the payroll aggregate — a per-month run whose lines are the prorated
//// salary owed each employed engineer. `handle` routes the payroll command to a
//// named operation that does ONLY its temporal writes on the in-transaction
//// connection and classifies any database rejection; `command.dispatch` owns the
//// transaction and persists the journal event(s) `handle` returns. No HTTP — never
//// imports `wisp`.
////
//// `run_payroll` is an Assert that also computes its lines: mint the run identity,
//// compute one prorated amount per employed engineer (`payroll_amounts` integrates
//// `monthly_salary[level]` over `employment ∩ role-version ∩ salary-version ∩ month`,
//// so a mid-month hire/termination is clipped, a promotion blends two salaries, and
//// leave is paid in full — FR-F5/F6), then snapshot one `payroll_line` per engineer.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, RunPayroll}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a payroll-aggregate command: route it to its named operation, then on
/// success return the journal event(s) it produced. The dispatch `route` only ever
/// sends payroll commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    RunPayroll(period_from:, period_to:) ->
      run_payroll(conn, period_from, period_to)
    _ ->
      panic as "payroll.handle: command not owned by this aggregate (dispatch bug)"
  }
  result.map(written, fn(_) { events(command) })
}

/// Run payroll for a month: mint the run identity, compute the prorated amount per
/// employed engineer for the period, and insert each as a `payroll_line` — all
/// threaded through the minted run id.
fn run_payroll(
  conn: pog.Connection,
  period_from: Date,
  period_to: Date,
) -> Result(Nil, OperationError) {
  use created <- operation.try(sql.payroll_run_create(
    conn,
    period_from,
    period_to,
  ))
  let run_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  use amounts <- operation.try(sql.payroll_amounts(conn, period_from, period_to))
  insert_lines(conn, run_id, amounts.rows)
}

/// Insert each computed payroll amount as a line for the run: engineer, the prorated
/// amount owed, and the employed days it covers (all from `payroll_amounts`).
fn insert_lines(
  conn: pog.Connection,
  run_id: Int,
  amounts: List(sql.PayrollAmountsRow),
) -> Result(Nil, OperationError) {
  list.try_map(amounts, fn(amount) {
    sql.payroll_line_insert(
      conn,
      run_id,
      amount.engineer_id,
      amount.amount,
      amount.days,
    )
  })
  |> operation.run
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
    _ ->
      panic as "payroll.events: command not owned by this aggregate (dispatch bug)"
  }
}
