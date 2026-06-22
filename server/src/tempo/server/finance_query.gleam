//// Domain: the financial READ queries (FR-F1/F4/F5/F7/F8). Each function runs a
//// Squirrel query and maps the rows to the shared read types the client renders;
//// the derived figures (profit, margin %, utilization %, the P&L totals) are
//// computed here in Gleam from the raw query components, not in SQL. No HTTP —
//// this layer never imports `wisp`; the web handlers reach the database only
//// through these functions.
////
//// The invoice list/detail and the payroll read are straight row→type maps. The
//// P&L is the one with arithmetic: `pnl` runs `sql.pnl_rows` over two windows —
//// the month containing the as-of date, and year-to-date (Jan 1 of that year to
//// the end of that month) — derives each engineer's profit/margin/utilization for
//// the month, and totals revenue/cost/profit for both windows. Windows are built
//// from the as-of `Date` by month arithmetic (first of the month, first of the
//// next month exclusive, first of the year).

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar.{type Date, Date, January}
import pog
import shared/types.{
  type Forecast, type ForecastMonth, type Invoice, type InvoiceDetail,
  type Payroll, type PayrollLine, type PayrollRunInfo, type Pnl, type PnlRow,
  Forecast, ForecastMonth, Invoice, InvoiceDetail, Payroll, PayrollLine,
  PayrollRunInfo, Pnl, PnlRow,
}
import tempo/server/context.{type Context}
import tempo/server/sql

// --- invoices ----------------------------------------------------------------

/// List every invoice with its status AS OF `as_of` and its line total
/// (FR-F1/FR-F4). Only invoices that have a status covering `as_of` appear —
/// scrubbing the slider before an invoice's billing month drops it, and within
/// the month it reads `draft` until its issue date.
pub fn list_invoices(
  context: Context,
  as_of: Date,
) -> Result(List(Invoice), pog.QueryError) {
  use returned <- result.map(sql.invoice_list(context.db, as_of))
  list.map(returned.rows, list_row_to_invoice)
}

fn list_row_to_invoice(row: sql.InvoiceListRow) -> Invoice {
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status: row.status,
    total: row.total,
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}

/// One invoice's detail (`GET /api/invoices/:id`): the header (status AS OF
/// `as_of`, total) plus its snapshot lines. Returns `Ok(None)` when no invoice
/// has that id, so the handler can answer a 404 rather than a 500.
pub fn invoice_detail(
  context: Context,
  invoice_id: Int,
  as_of: Date,
) -> Result(Result(InvoiceDetail, Nil), pog.QueryError) {
  use header <- result.try(sql.invoice_header(context.db, invoice_id, as_of))
  case header.rows {
    [] -> Ok(Error(Nil))
    [row, ..] -> {
      use lines <- result.map(sql.invoice_lines(context.db, invoice_id))
      Ok(InvoiceDetail(
        invoice: header_row_to_invoice(row),
        lines: list.map(lines.rows, lines_row_to_invoice_line),
      ))
    }
  }
}

fn header_row_to_invoice(row: sql.InvoiceHeaderRow) -> Invoice {
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status: row.status,
    total: row.total,
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}

fn lines_row_to_invoice_line(row: sql.InvoiceLinesRow) -> types.InvoiceLine {
  types.InvoiceLine(
    engineer: row.engineer,
    level: row.level,
    day_rate: row.day_rate,
    days: row.days,
    amount: row.amount,
  )
}

// --- payroll -----------------------------------------------------------------

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

// --- P&L ---------------------------------------------------------------------

/// The P&L statement for an as-of date (FR-F7/FR-F8). The "month" is the calendar
/// month containing `as_of`; "year-to-date" runs from Jan 1 of that year to the
/// end of that month. Per-engineer rows are the MONTH breakdown (revenue, cost,
/// derived profit/margin/utilization); the month totals are their sums, and the
/// YTD totals are a second `pnl_rows` pass over the wider window. Revenue is
/// recognized on issue and read AS OF each window's exclusive upper bound, so an
/// unissued invoice contributes nothing (carried through by `pnl_rows`).
pub fn pnl(context: Context, as_of: Date) -> Result(Pnl, pog.QueryError) {
  let month_start = first_of_month(as_of)
  let month_end = first_of_next_month(as_of)
  let year_start = first_of_year(as_of)

  use month <- result.try(sql.pnl_rows(context.db, month_start, month_end))
  use ytd <- result.map(sql.pnl_rows(context.db, year_start, month_end))

  let rows = list.map(month.rows, raw_row_to_pnl_row)
  let #(month_revenue, month_cost) = totals(month.rows)
  let #(ytd_revenue, ytd_cost) = totals(ytd.rows)

  Pnl(
    month_revenue:,
    month_cost:,
    month_profit: month_revenue -. month_cost,
    ytd_revenue:,
    ytd_cost:,
    ytd_profit: ytd_revenue -. ytd_cost,
    rows:,
  )
}

/// Map one `pnl_rows` component row to the shared `PnlRow`, deriving the figures
/// SQL left to the caller: profit = revenue − cost, margin % = profit / revenue
/// (0 when revenue is 0), utilization % = utilization_days / employed_days (0 when
/// employed_days is 0). Margin and utilization are expressed as percentages.
fn raw_row_to_pnl_row(row: sql.PnlRowsRow) -> PnlRow {
  PnlRow(
    engineer: row.engineer,
    revenue: row.revenue,
    cost: row.cost,
    profit: row.revenue -. row.cost,
    margin_pct: percentage(row.revenue -. row.cost, of: row.revenue),
    utilization_pct: percentage(row.utilization_days, of: row.employed_days),
  )
}

/// Sum revenue and cost across the per-engineer rows (the statement totals are the
/// sum of the breakdown, so the rows reconcile to the totals).
fn totals(rows: List(sql.PnlRowsRow)) -> #(Float, Float) {
  list.fold(rows, #(0.0, 0.0), fn(acc, row) {
    let #(revenue, cost) = acc
    #(revenue +. row.revenue, cost +. row.cost)
  })
}

/// `part / whole` as a percentage; 0.0 when `whole` is 0 (a guard against a
/// zero-revenue or zero-employment row dividing by zero).
fn percentage(part: Float, of whole: Float) -> Float {
  case whole {
    0.0 -> 0.0
    _ -> part /. whole *. 100.0
  }
}

// --- forecast ----------------------------------------------------------------

/// The forward P&L from committed demand (`GET /api/forecast?as_of=`). `sql.forecast`
/// returns one (month, revenue, cost) row per calendar month from the as-of month to
/// the cliff (the last day any requirement or allocation runs); per project per month
/// the demand is the project's requirements if any cover the month, else its
/// allocations (the (b) rule). This derives the per-month profit (revenue − cost) and
/// margin % (profit / revenue, 0 when revenue is 0) — the same derivation the P&L
/// does — leaving the cliff and the (b) switch to SQL.
pub fn forecast(
  context: Context,
  as_of: Date,
) -> Result(Forecast, pog.QueryError) {
  use returned <- result.map(sql.forecast(context.db, as_of))
  Forecast(months: list.map(returned.rows, forecast_row_to_month))
}

fn forecast_row_to_month(row: sql.ForecastRow) -> ForecastMonth {
  ForecastMonth(
    month: row.month,
    revenue: row.revenue,
    cost: row.cost,
    profit: row.revenue -. row.cost,
    margin_pct: percentage(row.revenue -. row.cost, of: row.revenue),
  )
}

// --- month arithmetic --------------------------------------------------------

/// The first day of the calendar month containing `date`.
fn first_of_month(date: Date) -> Date {
  Date(year: date.year, month: date.month, day: 1)
}

/// The first day of the month AFTER the one containing `date` (the exclusive upper
/// bound of the month window); December rolls over to the next January.
fn first_of_next_month(date: Date) -> Date {
  case calendar.month_to_int(date.month) {
    12 -> Date(year: date.year + 1, month: January, day: 1)
    month ->
      case calendar.month_from_int(month + 1) {
        Ok(next) -> Date(year: date.year, month: next, day: 1)
        // month + 1 is in 2..12 here, always valid; defensively keep January.
        Error(Nil) -> Date(year: date.year, month: January, day: 1)
      }
  }
}

/// The first day of the year containing `date` (the YTD window start).
fn first_of_year(date: Date) -> Date {
  Date(year: date.year, month: January, day: 1)
}
