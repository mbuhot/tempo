//// The P&L read models and their JSON codecs: one per-employee `PnlRow` and the
//// whole `Pnl` statement (month/YTD totals plus rows). Pure Gleam, no
//// target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Money/margin fields decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/wire

/// One per-employee row of the P&L statement (FR-F8): the engineer's `revenue`
/// (their invoice lines), `cost` (their payroll line), `profit` (revenue − cost),
/// `margin_pct` (profit / revenue), and `utilization_pct` (billable share of
/// employed days).
pub type PnlRow {
  PnlRow(
    engineer: String,
    revenue: Float,
    cost: Float,
    profit: Float,
    margin_pct: Float,
    utilization_pct: Float,
  )
}

/// The P&L statement read model (`GET /api/pnl?as_of=`, FR-F7/FR-F8): month and
/// year-to-date totals for revenue/cost/profit, plus the per-employee `rows`.
pub type Pnl {
  Pnl(
    month_revenue: Float,
    month_cost: Float,
    month_profit: Float,
    ytd_revenue: Float,
    ytd_cost: Float,
    ytd_profit: Float,
    rows: List(PnlRow),
  )
}

/// Encode a `PnlRow` (one per-employee P&L breakdown) as a JSON object.
pub fn encode_pnl_row(row: PnlRow) -> Json {
  let PnlRow(engineer:, revenue:, cost:, profit:, margin_pct:, utilization_pct:) =
    row
  json.object([
    #("engineer", json.string(engineer)),
    #("revenue", json.float(revenue)),
    #("cost", json.float(cost)),
    #("profit", json.float(profit)),
    #("margin_pct", json.float(margin_pct)),
    #("utilization_pct", json.float(utilization_pct)),
  ])
}

/// Decode a `PnlRow` from a JSON object.
pub fn pnl_row_decoder() -> Decoder(PnlRow) {
  use engineer <- decode.field("engineer", decode.string)
  use revenue <- decode.field("revenue", wire.lenient_float_decoder())
  use cost <- decode.field("cost", wire.lenient_float_decoder())
  use profit <- decode.field("profit", wire.lenient_float_decoder())
  use margin_pct <- decode.field("margin_pct", wire.lenient_float_decoder())
  use utilization_pct <- decode.field(
    "utilization_pct",
    wire.lenient_float_decoder(),
  )
  decode.success(PnlRow(
    engineer:,
    revenue:,
    cost:,
    profit:,
    margin_pct:,
    utilization_pct:,
  ))
}

/// Encode a `Pnl` statement (month/YTD totals plus per-employee rows) to JSON.
pub fn encode_pnl(pnl: Pnl) -> Json {
  let Pnl(
    month_revenue:,
    month_cost:,
    month_profit:,
    ytd_revenue:,
    ytd_cost:,
    ytd_profit:,
    rows:,
  ) = pnl
  json.object([
    #("month_revenue", json.float(month_revenue)),
    #("month_cost", json.float(month_cost)),
    #("month_profit", json.float(month_profit)),
    #("ytd_revenue", json.float(ytd_revenue)),
    #("ytd_cost", json.float(ytd_cost)),
    #("ytd_profit", json.float(ytd_profit)),
    #("rows", json.array(rows, encode_pnl_row)),
  ])
}

/// Decode a `Pnl` statement from JSON.
pub fn pnl_decoder() -> Decoder(Pnl) {
  use month_revenue <- decode.field(
    "month_revenue",
    wire.lenient_float_decoder(),
  )
  use month_cost <- decode.field("month_cost", wire.lenient_float_decoder())
  use month_profit <- decode.field("month_profit", wire.lenient_float_decoder())
  use ytd_revenue <- decode.field("ytd_revenue", wire.lenient_float_decoder())
  use ytd_cost <- decode.field("ytd_cost", wire.lenient_float_decoder())
  use ytd_profit <- decode.field("ytd_profit", wire.lenient_float_decoder())
  use rows <- decode.field("rows", decode.list(pnl_row_decoder()))
  decode.success(Pnl(
    month_revenue:,
    month_cost:,
    month_profit:,
    ytd_revenue:,
    ytd_cost:,
    ytd_profit:,
    rows:,
  ))
}
