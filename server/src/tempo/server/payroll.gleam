//// Domain: the payroll aggregate — a per-month run whose lines are the prorated
//// salary owed each employed engineer. `command.route` destructures the payroll
//// command and calls the operation here with its already-narrowed fields; the
//// operation returns the `Fact`s it records, and `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// `run_payroll` reserves the run id, computes one prorated amount per employed
//// engineer (`payroll_amounts` integrates `monthly_salary[level]` over `employment ∩
//// role-version ∩ salary-version ∩ month`, so a mid-month hire/termination is
//// clipped, a promotion blends two salaries, and leave is paid in full — FR-F5/F6),
//// and records the anchor, its period, and one line per row.

import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository
import tempo/server/sql

/// Run payroll for a month: reserve the run id, compute the prorated amount per
/// employed engineer, and record the anchor, its period, and one line per row, with
/// the journal entry.
pub fn run_payroll(
  conn: pog.Connection,
  command: Command,
  period_from period_from: Date,
  period_to period_to: Date,
) -> Result(Recorded, OperationError) {
  use run_id <- result.try(repository.create_payroll_run(conn))
  let fact.PayrollRunId(id) = run_id
  use amounts <- operation.try(sql.payroll_amounts(conn, period_from, period_to))
  let line_facts =
    list.map(amounts.rows, fn(line) {
      fact.PayrollLine(
        run_id:,
        engineer_id: fact.EngineerId(line.engineer_id),
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
        <> int.to_string(id)
        <> ")",
      payload: codecs.encode_command(command),
    ),
    facts: list.flatten([
      [fact.PayrollPeriod(run_id:, from: period_from, to: period_to)],
      line_facts,
    ]),
  ))
}
