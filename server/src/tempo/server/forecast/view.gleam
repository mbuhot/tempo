//// Domain: the forecast READ query — the forward P&L from committed demand
//// (`GET /api/forecast?as_of=`). `sql.forecast` returns one (month, revenue, cost)
//// row per calendar month from the as-of month to the cliff (the last day any
//// requirement or allocation runs); per project per month the demand is the
//// project's requirements if any cover the month, else its allocations (the (b)
//// rule). This derives the per-month profit (revenue − cost, exact `Money`) and
//// margin % (profit / revenue, 0 when revenue is 0) — the same derivation the P&L
//// does — leaving the cliff and the (b) switch to SQL.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/forecast/view.{
  type Forecast, type ForecastMonth, Forecast, ForecastMonth,
} as _
import shared/money.{type Money}
import tempo/server/context.{type Context}
import tempo/server/forecast/sql

/// Parse a money amount from a trusted SQL `numeric::text` column.
fn money(text: String) -> Money {
  let assert Ok(amount) = money.from_string(text)
  amount
}

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
  let revenue = money(row.revenue)
  let cost = money(row.cost)
  let profit = money.subtract(revenue, cost)
  ForecastMonth(
    month: row.month,
    revenue:,
    cost:,
    profit:,
    margin_pct: money.ratio(profit, revenue) *. 100.0,
  )
}
