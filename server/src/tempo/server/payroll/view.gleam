//// Domain: the payroll READ query (FR-F5/FR-F6). It runs the reconciliation
//// Squirrel query and maps the rows to the shared payroll read types the client
//// renders, folding in each line's per-level breakdown — the LIVE preview segments
//// (payroll_segments) and the FROZEN paid segments (payroll_line_segment) — keyed by
//// engineer_id. No HTTP — this layer never imports `wisp`; the web handler reaches
//// the database only through this function.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/money.{type Money}
import shared/payroll/view.{
  type Payroll, type PayrollLine, type PayrollRunInfo, type PayrollSegment,
  Payroll, PayrollLine, PayrollRunInfo, PayrollSegment,
} as _
import tempo/server/context.{type Context}
import tempo/server/payroll/sql

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

/// The month's payroll panel (`GET /api/payroll?from=&to=`): one `PayrollLine`
/// per engineer present on either side of the reconciliation — the LIVE recompute
/// over current facts (`preview_*`, always present) and the MATERIALIZED snapshot
/// a `RunPayroll` froze (`paid_*`, `None` until a run exists) (FR-F5/FR-F6) — each
/// carrying its per-level breakdown: the live `preview_segments` (payroll_segments)
/// and the frozen `paid_segments` (payroll_line_segment). `run` is `Some` iff a
/// materialized run covers the month; the variance preview − paid surfaces back-pay
/// owed after a back-dated fact moves the live slices.
pub fn payroll(
  context: Context,
  period_from: Date,
  period_to: Date,
) -> Result(Payroll, pog.QueryError) {
  use reconciliation <- result.try(sql.payroll_reconciliation(
    context.db,
    period_from,
    period_to,
  ))
  use preview <- result.try(sql.payroll_segments(
    context.db,
    period_from,
    period_to,
  ))
  use paid <- result.map(sql.payroll_paid_segments(
    context.db,
    period_from,
    period_to,
  ))
  let preview_by_engineer =
    group_segments(preview.rows, fn(row) {
      #(
        row.engineer_id,
        PayrollSegment(
          level: row.level,
          days: row.days,
          monthly_salary: money(row.monthly_salary),
          amount: money(row.amount),
        ),
      )
    })
  let paid_by_engineer =
    group_segments(paid.rows, fn(row) {
      #(
        row.engineer_id,
        PayrollSegment(
          level: row.level,
          days: row.days,
          monthly_salary: money(row.monthly_salary),
          amount: money(row.amount),
        ),
      )
    })
  Payroll(
    period_from:,
    period_to:,
    run: run_info(reconciliation.rows),
    lines: list.map(reconciliation.rows, fn(row) {
      payroll_row_to_line(row, preview_by_engineer, paid_by_engineer)
    }),
  )
}

/// Fold per-(engineer, level) segment rows into a `engineer_id -> [segment]` dict,
/// preserving the query's engineer-then-level order within each engineer's list.
fn group_segments(
  rows: List(row),
  to_entry: fn(row) -> #(Int, PayrollSegment),
) -> Dict(Int, List(PayrollSegment)) {
  rows
  |> list.fold(dict.new(), fn(acc, row) {
    let #(engineer_id, segment) = to_entry(row)
    dict.upsert(acc, engineer_id, fn(existing) {
      case existing {
        Some(segments) -> [segment, ..segments]
        None -> [segment]
      }
    })
  })
  |> dict.map_values(fn(_, segments) { list.reverse(segments) })
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

fn payroll_row_to_line(
  row: sql.PayrollReconciliationRow,
  preview_by_engineer: Dict(Int, List(PayrollSegment)),
  paid_by_engineer: Dict(Int, List(PayrollSegment)),
) -> PayrollLine {
  PayrollLine(
    engineer_id: row.engineer_id,
    engineer: row.engineer,
    preview_amount: money(row.preview_amount),
    preview_days: row.preview_days,
    paid_amount: option.map(row.paid_amount, money),
    paid_days: row.paid_days,
    preview_segments: dict.get(preview_by_engineer, row.engineer_id)
      |> result.unwrap([]),
    paid_segments: dict.get(paid_by_engineer, row.engineer_id)
      |> result.unwrap([]),
  )
}
