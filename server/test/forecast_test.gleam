//// Layer-3 forecast READ tests (ADR-044) for `finance_query.forecast` — the
//// forward P&L from committed demand (`GET /api/forecast?as_of=`). They run
//// against the deterministic seed ("now" = 2026-06-15), whose committed demand is:
////   * allocations (supply) on projects 100/200/300, all running to 2027-01-01;
////   * Edge Analytics (project 500) requirements 2× L3 + 1× L4 + 0.5× L5 over
////     2026-08-01..2027-01-01 — priced from the rate card directly (no engineers).
//// So the cliff (the last day any requirement or allocation runs) is 2027-01-01,
//// and the forecast spans the as-of month (June 2026) through December 2026.
////
//// ISOLATION (as in pnl_test.gleam): each test reads through `finance_query.forecast`
//// inside its OWN `pog.transaction`, then returns `Error(…)` so nothing is committed
//// and the shared seed is undisturbed. These tests only READ, so they add no fixture.

import gleam/list
import gleam/time/calendar.{
  type Date, August, Date, December, July, June, November, October, September,
}
import pog
import shared/forecast/view.{type Forecast}
import tempo/server/context.{Context}
import tempo/server/finance_query
import test_pool

/// Run `body` inside a transaction, then roll back, smuggling its return value out
/// through `TransactionRolledBack` so the seed is never mutated.
fn rolling_back(body: fn(pog.Connection) -> a) -> a {
  let outcome = pog.transaction(test_pool.db(), fn(conn) { Error(body(conn)) })
  let assert Error(pog.TransactionRolledBack(value)) = outcome
  value
}

/// The forecast as-of `as_of`, asserted to succeed.
fn forecast(conn: pog.Connection, as_of: Date) -> Forecast {
  let assert Ok(forecast) = finance_query.forecast(Context(db: conn), as_of)
  forecast
}

// --- horizon (the cliff and the as-of month) --------------------------------

// The forecast runs one contiguous month per calendar month from the as-of month
// to the cliff. At the seed "now" (2026-06-15) the cliff is 2027-01-01, so the
// horizon is exactly June..December 2026 — seven contiguous first-of-month dates.
pub fn forecast_runs_from_as_of_month_to_the_cliff_test() {
  let months =
    rolling_back(fn(conn) {
      forecast(conn, Date(2026, June, 15)).months
      |> list.map(fn(month) { month.month })
    })

  assert months
    == [
      Date(2026, June, 1),
      Date(2026, July, 1),
      Date(2026, August, 1),
      Date(2026, September, 1),
      Date(2026, October, 1),
      Date(2026, November, 1),
      Date(2026, December, 1),
    ]
}

// Past the cliff there is no committed demand ahead, so the forecast is empty —
// an as-of in mid-2027 (after every allocation and requirement has ended)
// produces no months at all.
pub fn forecast_past_the_cliff_is_empty_test() {
  let months =
    rolling_back(fn(conn) { forecast(conn, Date(2027, June, 1)).months })

  assert months == []
}

// --- the derivation finance_query owns (profit and margin per month) --------

// Each month's profit is exactly revenue − cost and its margin is profit / revenue
// (the same derivation the P&L does, applied per month). Every month in the seed
// horizon carries revenue from the active allocations, so none is a zero-revenue
// row and the margin is always the genuine ratio.
pub fn forecast_profit_and_margin_are_derived_per_month_test() {
  let months =
    rolling_back(fn(conn) { forecast(conn, Date(2026, June, 15)).months })

  assert list.all(months, fn(month) {
    month.profit == month.revenue -. month.cost
    && month.revenue >. 0.0
    && month.margin_pct == month.profit /. month.revenue *. 100.0
  })
}
