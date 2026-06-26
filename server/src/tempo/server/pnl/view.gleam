//// Domain: the P&L READ query (FR-F7/FR-F8). This is the read with arithmetic:
//// `pnl` runs `sql.pnl_rows` over two windows — the month containing the as-of
//// date, and year-to-date (Jan 1 of that year to the end of that month) — derives
//// each engineer's profit/margin/utilization for the month, and totals
//// revenue/cost/profit for both windows. Windows are built from the as-of `Date`
//// by month arithmetic (first of the month, first of the next month exclusive,
//// first of the year). No HTTP — the web handler reaches the database only
//// through this function. `percentage` is the shared profit/margin derivation the
//// forecast read also uses.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date, Date, January}
import pog
import shared/pnl/view.{type Pnl, type PnlRow, Pnl, PnlRow} as _
import tempo/server/context.{type Context}
import tempo/server/pnl/sql

/// The P&L statement for an as-of date (FR-F7/FR-F8). The "month" is the calendar
/// month containing `as_of`; "year-to-date" runs from Jan 1 of that year to the
/// end of that month. Per-engineer rows are the MONTH breakdown (revenue, cost,
/// derived profit/margin/utilization); the month totals are their sums, and the
/// YTD totals are a second `pnl_rows` pass over the wider window. The two queries
/// stay sequential (not fanned out): `pnl_test` drives this through a rolled-back
/// `pog.transaction` fixture on a single connection, which a concurrent fan-out
/// cannot share. Revenue is recognized on issue and read AS OF each window's
/// exclusive upper bound, so an unissued invoice contributes nothing (carried
/// through by `pnl_rows`).
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
pub fn percentage(part: Float, of whole: Float) -> Float {
  case whole {
    0.0 -> 0.0
    _ -> part /. whole *. 100.0
  }
}

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
