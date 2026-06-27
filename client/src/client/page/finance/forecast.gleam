//// The Finance Forecast tab (FR-F*), a self-contained sub-component MVU split out
//// of `client/page/finance`. The tab owns its own `Model` (its as-of, the loaded
//// forecast summary read model, and the forecast table host), its own `Msg`, its
//// `init`/`update`, and its `view`.
////
//// The forward P&L from committed demand. The month rows render via the generic
//// data table, embedded through `table_host` (which owns the load state, infinite
//// scroll, debounce, and column-layout persistence), reading
//// `GET /api/forecast/table?as_of=&filter.*=&sort=&page_size=&cursor=`. The total to
//// the cliff lives OUTSIDE the table (the generic table has no footer row): the tab
//// keeps fetching the summary `GET /api/forecast?as_of=` and renders the to-the-cliff
//// total below the table. Each summary result carries the `as_of` it answers so a
//// stale reply is dropped. The months don't drill anywhere, so the host's
//// `Activated` outcome is inert.

import client/api
import client/page.{type OutMsg}
import client/table_host
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
import shared/forecast/view.{type Forecast} as forecast_view
import shared/money

/// The Forecast tab's state: the as-of its data answers, the load state of the
/// forecast summary read model (for the to-the-cliff total), and the month table
/// host.
pub type Model {
  Model(as_of: calendar.Date, forecast: Load, host: table_host.Host)
}

/// The forecast summary read model's load state.
pub type Load {
  Loading
  Loaded(forecast: Forecast)
  Failed(message: String)
}

/// The tab's messages: the summary fetch result (carrying the `as_of` it answers)
/// and the embedded table host's sub-messages.
pub type Msg {
  GotForecast(
    as_of: calendar.Date,
    result: Result(Forecast, rsvp.Error(String)),
  )
  TableHostMsg(sub: table_host.Msg)
}

/// Start the tab at `as_of`, kicking off its summary fetch and the table host.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.init("/api/forecast/table", as_of)
  #(
    Model(as_of:, forecast: Loading, host:),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate): the current view
/// stays on screen until the fresh result lands.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  #(
    Model(as_of:, forecast: Loading, host:),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
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

    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id: _) -> #(model, effect, [])
      }
    }
  }
}

/// Render the tab: a loading guard on the summary read, delegating the loaded render
/// to `panel`.
pub fn view(model: Model) -> Element(Msg) {
  case model.forecast {
    Loading -> ui.empty_state(message: "Loading forecast…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(forecast:) -> panel(model, forecast)
  }
}

/// Render the forecast for a loaded summary: the month rows via the generic table
/// embedded through its host, with the to-the-cliff total rendered below the table
/// (the generic table has no footer row), or an empty-state when no month carries
/// committed demand.
fn panel(model: Model, forecast: Forecast) -> Element(Msg) {
  case forecast.months {
    [] ->
      ui.panel(title: "Forecast", count: "0 months", right: [], body: [
        ui.empty_state(message: "No committed demand to forecast on this date."),
      ])
    months -> {
      let count = list.length(months)
      let total_revenue =
        money.sum(list.map(months, fn(month) { month.revenue }))
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
          element.map(
            table_host.view(model.host, "Loading forecast…"),
            TableHostMsg,
          ),
          total_row(total_revenue, total_cost, total_profit, total_margin),
        ],
      )
    }
  }
}

/// The to-the-cliff total, summing each money column with the blended margin —
/// rendered as a standalone strip below the month table.
fn total_row(
  revenue: money.Money,
  cost: money.Money,
  profit: money.Money,
  margin: Float,
) -> Element(Msg) {
  let #(profit_class, profit_text) = forecast_profit(profit)
  html.div([attribute.class("finance__total-row")], [
    html.span([], [html.text("Total")]),
    html.span([attribute.class("num")], [
      html.text(ui.money(money.to_float(revenue))),
    ]),
    html.span([attribute.class("num")], [
      html.text(ui.money(money.to_float(cost))),
    ]),
    html.span([attribute.class(profit_class)], [html.text(profit_text)]),
    html.span([attribute.class("num")], [html.text(ui.pct(margin))]),
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
