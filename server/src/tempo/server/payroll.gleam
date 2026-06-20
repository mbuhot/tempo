//// Domain: the payroll aggregate — a per-month run whose lines are the prorated
//// salary owed each employed engineer. `handle` routes the payroll command to a
//// named operation that returns the `Fact`s it records; `command.dispatch` records
//// them (through `repository`) and persists the journal in ONE transaction. No HTTP
//// — never imports `wisp`.
////
//// `run_payroll` reserves the run id, computes one prorated amount per employed
//// engineer (`payroll_amounts` integrates `monthly_salary[level]` over `employment ∩
//// role-version ∩ salary-version ∩ month`, so a mid-month hire/termination is
//// clipped, a promotion blends two salaries, and leave is paid in full — FR-F5/F6),
//// and records the anchor, its period, and one line per row.

import gleam/int
import gleam/list
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, RunPayroll}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository
import tempo/server/sql

/// Apply a payroll-aggregate command: route it to its named operation, which returns
/// the audit entry and facts it records. The dispatch `route` only ever sends payroll
/// commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    RunPayroll(..) -> run_payroll(conn, command)
    _ ->
      panic as "payroll.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Run payroll for a month: reserve the run id, compute the prorated amount per
/// employed engineer, and record the anchor, its period, and one line per row, with
/// the journal entry.
fn run_payroll(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert RunPayroll(period_from:, period_to:) = command
  use run_id <- result.try(repository.next_id(conn, repository.PayrollRuns))
  use amounts <- operation.try(sql.payroll_amounts(conn, period_from, period_to))
  let line_facts =
    list.map(amounts.rows, fn(line) {
      fact.PayrollLine(
        run_id:,
        engineer_id: line.engineer_id,
        amount: line.amount,
        days: line.days,
      )
    })
  Ok(Recorded(
    entry: Event(
      operation: "run_payroll",
      summary: "Run payroll over "
        <> operation.span(period_from, period_to)
        <> " (run "
        <> int.to_string(run_id)
        <> ")",
      payload: codecs.encode_command(command),
    ),
    facts: list.flatten([
      [
        fact.PayrollRun(id: run_id),
        fact.PayrollPeriod(run_id:, from: period_from, to: period_to),
      ],
      line_facts,
    ]),
  ))
}
