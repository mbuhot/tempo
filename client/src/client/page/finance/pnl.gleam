//// The Finance P&L tab's view (FR-F*), split out of `client/page/finance` so the
//// tab owns its own rendering without colliding in the page's single `view`. The
//// tab is read-only — it emits no messages — so `view` is generic over the host
//// page's `msg` and slots straight into the parent with no `element.map`.
////
//// `view` renders the month and year-to-date revenue/cost/profit stat trios (the
//// month margin badged on profit) and the per-engineer P&L table. The page passes
//// the loaded `Pnl` and the rail `as_of` (for the month/year labels).

import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import shared/types.{type Pnl, type PnlRow}

/// Render the P&L tab for a loaded `pnl` as of `as_of`: two stat trios (this month
/// and year-to-date) and the per-engineer table. Generic over `msg` since the tab
/// raises none.
pub fn view(pnl: Pnl, as_of: calendar.Date) -> Element(msg) {
  let month = time.format_month(time.first_of_month(as_of))
  let margin_pct = case pnl.month_revenue >. 0.0 {
    True -> ui.Pct(float.round(pnl.month_profit /. pnl.month_revenue *. 100.0))
    False -> ui.NoPct
  }
  let ytd_margin_pct = case pnl.ytd_revenue >. 0.0 {
    True -> ui.Pct(float.round(pnl.ytd_profit /. pnl.ytd_revenue *. 100.0))
    False -> ui.NoPct
  }
  let year = int.to_string(time.first_of_month(as_of).year)
  let rows = list.map(pnl.rows, pnl_row)
  html.div([], [
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(pnl.month_revenue),
        unit: "/mo",
        label: "Revenue · " <> month,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(pnl.month_cost),
        unit: "/mo",
        label: "Cost · " <> month,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(pnl.month_profit),
        unit: "/mo",
        label: "Profit · " <> month,
        pct: margin_pct,
      ),
    ]),
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(pnl.ytd_revenue),
        unit: "YTD",
        label: "Revenue · since Jan " <> year,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(pnl.ytd_cost),
        unit: "YTD",
        label: "Cost · since Jan " <> year,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(pnl.ytd_profit),
        unit: "YTD",
        label: "Profit · since Jan " <> year,
        pct: ytd_margin_pct,
      ),
    ]),
    ui.panel(
      title: "Profit & loss · " <> month,
      count: "per engineer",
      right: [],
      body: [
        ui.data_table(
          headers: [
            #("Engineer", False),
            #("Revenue", True),
            #("Cost", True),
            #("Profit", True),
            #("Margin", True),
            #("Utilization", True),
          ],
          rows: rows,
        ),
      ],
    ),
  ])
}

fn pnl_row(row: PnlRow) -> Element(msg) {
  let profit_class = case row.profit >=. 0.0 {
    True -> "num pnl__profit--positive"
    False -> "num pnl__profit--negative"
  }
  let profit_text = case row.profit >=. 0.0 {
    True -> ui.money(row.profit)
    False -> "−" <> ui.money(float.absolute_value(row.profit))
  }
  html.tr([], [
    html.td([], [html.text(row.engineer)]),
    html.td([attribute.class("num")], [html.text(ui.money(row.revenue))]),
    html.td([attribute.class("num")], [html.text(ui.money(row.cost))]),
    html.td([attribute.class(profit_class)], [html.text(profit_text)]),
    html.td([attribute.class("num")], [html.text(ui.pct(row.margin_pct))]),
    html.td([attribute.class("num")], [html.text(ui.pct(row.utilization_pct))]),
  ])
}
