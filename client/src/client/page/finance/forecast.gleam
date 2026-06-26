//// The Finance Forecast tab (FR-F*), a self-contained sub-component MVU split out
//// of `client/page/finance`. The tab owns its own `Model` (its as-of and the
//// loaded forecast read model), its own `Msg`, its `init`/`update`, and its
//// `view`. It is read-only: the only message it raises is its own fetch result.
////
//// The forward P&L from committed demand (`GET /api/forecast?as_of=`): one row per
//// calendar month from the as-of month to the cliff (Month | Revenue | Cost |
//// Profit | Margin), capped by a total row summing each money column with the
//// blended margin. An empty-state when no month carries demand. Each result
//// carries the `as_of` it answers so a stale reply is dropped.

import client/api
import client/page.{type OutMsg}
import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/forecast/view.{type Forecast, type ForecastMonth} as forecast_view
import shared/money

/// The Forecast tab's state: the as-of its data answers and the load state of the
/// forecast read model.
pub type Model {
  Model(as_of: calendar.Date, forecast: Load)
}

/// The forecast read model's load state.
pub type Load {
  Loading
  Loaded(forecast: Forecast)
  Failed(message: String)
}

/// The tab's messages: its own fetch result, carrying the `as_of` it answers.
pub type Msg {
  GotForecast(
    as_of: calendar.Date,
    result: Result(Forecast, rsvp.Error(String)),
  )
}

/// Start the tab at `as_of`, kicking off its forecast fetch.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, forecast: Loading), fetch(as_of))
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate).
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, forecast: Loading), fetch(as_of))
}

fn fetch(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/forecast?as_of=" <> time.iso_date(as_of),
    forecast_view.forecast_decoder(),
    GotForecast(as_of, _),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotForecast(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let forecast = case result {
            Ok(forecast) -> Loaded(forecast:)
            Error(error) -> Failed(message: api.describe_error(error))
          }
          #(Model(..model, forecast:), effect.none(), [])
        }
      }
  }
}

/// Render the tab: a loading guard, delegating the loaded render to `panel`.
pub fn view(model: Model) -> Element(Msg) {
  case model.forecast {
    Loading -> ui.empty_state(message: "Loading forecast…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(forecast:) -> panel(forecast)
  }
}

/// Render the forecast for a loaded `forecast`: a month-by-month table to the
/// demand cliff with a summing total row, or an empty-state when no month carries
/// committed demand. Generic over `msg` since it raises none.
pub fn panel(forecast: Forecast) -> Element(msg) {
  case forecast.months {
    [] ->
      ui.panel(title: "Forecast", count: "0 months", right: [], body: [
        ui.empty_state(message: "No committed demand to forecast on this date."),
      ])
    months -> {
      let count = list.length(months)
      let total_revenue = money.sum(list.map(months, fn(month) { month.revenue }))
      let total_cost = money.sum(list.map(months, fn(month) { month.cost }))
      let total_profit = money.subtract(total_revenue, total_cost)
      let total_margin = case money.to_float(total_revenue) >. 0.0 {
        True -> money.ratio(total_profit, total_revenue) *. 100.0
        False -> 0.0
      }
      ui.panel(
        title: "Forecast",
        count: int.to_string(count) <> " months",
        right: [
          html.span([attribute.class("finance__total-note")], [
            html.text(
              ui.money(money.to_float(total_revenue)) <> " revenue to the cliff",
            ),
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
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(month.revenue))),
    ]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(month.cost))),
    ]),
    html.td([attribute.class(profit_class)], [html.text(profit_text)]),
    html.td([attribute.class("num")], [html.text(ui.pct(month.margin_pct))]),
  ])
}

fn forecast_total_row(
  revenue: money.Money,
  cost: money.Money,
  profit: money.Money,
  margin: Float,
) -> Element(msg) {
  let #(profit_class, profit_text) = forecast_profit(profit)
  html.tr([attribute.class("finance__total-row")], [
    html.td([], [html.text("Total")]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(revenue))),
    ]),
    html.td([attribute.class("num")], [html.text(ui.money(money.to_float(cost)))]),
    html.td([attribute.class(profit_class)], [html.text(profit_text)]),
    html.td([attribute.class("num")], [html.text(ui.pct(margin))]),
  ])
}

/// The profit cell's class and signed text, mirroring the P&L table's positive /
/// negative colouring (a leading minus glyph on a loss).
fn forecast_profit(profit: money.Money) -> #(String, String) {
  let profit = money.to_float(profit)
  case profit >=. 0.0 {
    True -> #("num pnl__profit--positive", ui.money(profit))
    False -> #(
      "num pnl__profit--negative",
      "−" <> ui.money(float.absolute_value(profit)),
    )
  }
}
