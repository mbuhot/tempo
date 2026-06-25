//// Domain: the payroll READ query (FR-F5/FR-F6). It runs the reconciliation
//// Squirrel query and maps the rows to the shared payroll read types the client
//// renders. No HTTP — this layer never imports `wisp`; the web handler reaches
//// the database only through this function.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/payroll/view.{
  type Payroll, type PayrollLine, type PayrollRunInfo, Payroll, PayrollLine,
  PayrollRunInfo,
} as _
import tempo/server/context.{type Context}
import tempo/server/payroll/sql

/// The month's payroll panel (`GET /api/payroll?from=&to=`): one `PayrollLine`
/// per engineer present on either side of the reconciliation — the LIVE recompute
/// over current facts (`preview_*`, always present) and the MATERIALIZED snapshot
/// a `RunPayroll` froze (`paid_*`, `None` until a run exists) (FR-F5/FR-F6). `run`
/// is `Some` iff a materialized run covers the month (carried on every row by the
/// query); the variance preview − paid surfaces back-pay owed after a back-dated
/// fact moves the live slices.
pub fn payroll(
  context: Context,
  period_from: Date,
  period_to: Date,
) -> Result(Payroll, pog.QueryError) {
  use returned <- result.map(sql.payroll_reconciliation(
    context.db,
    period_from,
    period_to,
  ))
  Payroll(
    period_from:,
    period_to:,
    run: run_info(returned.rows),
    lines: list.map(returned.rows, payroll_row_to_line),
  )
}

/// The materialized run for the month, read off any row's `run_id` (the query
/// carries the same value on every row); `None` when no run exists yet.
fn run_info(
  rows: List(sql.PayrollReconciliationRow),
) -> Option(PayrollRunInfo) {
  case rows {
    [row, ..] ->
      case row.run_id {
        Some(run_id) -> Some(PayrollRunInfo(run_id:))
        None -> None
      }
    [] -> None
  }
}

fn payroll_row_to_line(row: sql.PayrollReconciliationRow) -> PayrollLine {
  PayrollLine(
    engineer: row.engineer,
    preview_amount: row.preview_amount,
    preview_days: row.preview_days,
    paid_amount: row.paid_amount,
    paid_days: row.paid_days,
  )
}
