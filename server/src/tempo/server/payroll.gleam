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

import gleam/int
import gleam/list
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, RunPayroll}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a payroll-aggregate command: route it to its named operation, which does its
/// temporal writes and returns the journal event(s) it produced. The dispatch `route`
/// only ever sends payroll commands here, so any other variant is a routing bug —
/// `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    RunPayroll(..) -> run_payroll(conn, command)
    _ ->
      panic as "payroll.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Run payroll for a month: mint the run identity, compute the prorated amount per
/// employed engineer for the period, and insert each as a `payroll_line` — all
/// threaded through the minted run id — then return its journal event carrying that
/// run id.
fn run_payroll(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert RunPayroll(period_from:, period_to:) = command
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
  use _ <- result.try(insert_lines(conn, run_id, amounts.rows))
  Ok([
    Event(
      operation: "run_payroll",
      summary: "Run payroll over "
        <> operation.span(period_from, period_to)
        <> " (run "
        <> int.to_string(run_id)
        <> ")",
      payload: codecs.encode_command(command),
    ),
  ])
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
