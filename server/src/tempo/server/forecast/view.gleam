//// Domain: the forecast READ query — the forward P&L from committed demand
//// (`GET /api/forecast?as_of=`). `sql.forecast` returns one (month, revenue, cost)
//// row per calendar month from the as-of month to the cliff (the last day any
//// requirement or allocation runs); per project per month the demand is the
//// project's requirements if any cover the month, else its allocations (the (b)
//// rule). This derives the per-month profit (revenue − cost) and margin %
//// (profit / revenue, 0 when revenue is 0) — the same derivation the P&L does,
//// reusing `pnl/view.percentage` — leaving the cliff and the (b) switch to SQL.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/forecast/view.{
  type Forecast, type ForecastMonth, Forecast, ForecastMonth,
} as _
import tempo/server/context.{type Context}
import tempo/server/pnl/view as pnl_view
import tempo/server/sql

/// The forward P&L from committed demand (`GET /api/forecast?as_of=`); one
/// `ForecastMonth` per calendar month from the as-of month to the cliff, with the
/// per-month profit and margin derived from the query's revenue and cost.
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
    margin_pct: pnl_view.percentage(row.revenue -. row.cost, of: row.revenue),
  )
}
