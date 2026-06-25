//// The Finance Forecast tab's view (FR-F*), split out of `client/page/finance` so
//// the tab owns its own rendering. The tab is read-only — it emits no messages —
//// so `view` is generic over the host page's `msg` and slots straight into the
//// parent with no `element.map`.
////
//// The forward P&L from committed demand (`GET /api/forecast?as_of=`): one row per
//// calendar month from the as-of month to the cliff (Month | Revenue | Cost |
//// Profit | Margin), capped by a total row summing each money column with the
//// blended margin. An empty-state when no month carries demand.

import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import shared/forecast/view.{type Forecast, type ForecastMonth}

/// Render the Forecast tab for a loaded `forecast`: a month-by-month table to the
/// demand cliff with a summing total row, or an empty-state when no month carries
/// committed demand. Generic over `msg` since the tab raises none.
pub fn view(forecast: Forecast) -> Element(msg) {
  case forecast.months {
    [] ->
      ui.panel(title: "Forecast", count: "0 months", right: [], body: [
        ui.empty_state(message: "No committed demand to forecast on this date."),
      ])
    months -> {
      let count = list.length(months)
      let total_revenue =
        list.fold(months, 0.0, fn(sum, month) { sum +. month.revenue })
      let total_cost =
        list.fold(months, 0.0, fn(sum, month) { sum +. month.cost })
      let total_profit = total_revenue -. total_cost
      let total_margin = case total_revenue >. 0.0 {
        True -> total_profit /. total_revenue *. 100.0
        False -> 0.0
      }
      ui.panel(
        title: "Forecast",
        count: int.to_string(count) <> " months",
        right: [
          html.span([attribute.class("finance__total-note")], [
            html.text(ui.money(total_revenue) <> " revenue to the cliff"),
          ]),
        ],
        body: [
          ui.data_table(
            headers: [
              #("Month", False),
              #("Revenue", True),
              #("Cost", True),
              #("Profit", True),
              #("Margin", True),
            ],
            rows: list.append(list.map(months, forecast_row), [
              forecast_total_row(
                total_revenue,
                total_cost,
                total_profit,
                total_margin,
              ),
            ]),
          ),
        ],
      )
    }
  }
}

fn forecast_row(month: ForecastMonth) -> Element(msg) {
  let #(profit_class, profit_text) = forecast_profit(month.profit)
  html.tr([], [
    html.td([], [html.text(time.format_month(month.month))]),
    html.td([attribute.class("num")], [html.text(ui.money(month.revenue))]),
    html.td([attribute.class("num")], [html.text(ui.money(month.cost))]),
    html.td([attribute.class(profit_class)], [html.text(profit_text)]),
    html.td([attribute.class("num")], [html.text(ui.pct(month.margin_pct))]),
  ])
}

fn forecast_total_row(
  revenue: Float,
  cost: Float,
  profit: Float,
  margin: Float,
) -> Element(msg) {
  let #(profit_class, profit_text) = forecast_profit(profit)
  html.tr([attribute.class("finance__total-row")], [
    html.td([], [html.text("Total")]),
    html.td([attribute.class("num")], [html.text(ui.money(revenue))]),
    html.td([attribute.class("num")], [html.text(ui.money(cost))]),
    html.td([attribute.class(profit_class)], [html.text(profit_text)]),
    html.td([attribute.class("num")], [html.text(ui.pct(margin))]),
  ])
}

/// The profit cell's class and signed text, mirroring the P&L table's positive /
/// negative colouring (a leading minus glyph on a loss).
fn forecast_profit(profit: Float) -> #(String, String) {
  case profit >=. 0.0 {
    True -> #("num pnl__profit--positive", ui.money(profit))
    False -> #(
      "num pnl__profit--negative",
      "−" <> ui.money(float.absolute_value(profit)),
    )
  }
}
