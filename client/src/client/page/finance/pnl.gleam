//// The Finance P&L tab (FR-F*), a self-contained sub-component MVU split out of
//// `client/page/finance`. The tab owns its own `Model` (its as-of and the loaded
//// P&L read model), its own `Msg`, its `init`/`update`, and its `view`. It is
//// read-only: the only message it raises is its own fetch result.
////
//// The model reads `GET /api/pnl?as_of=`; each result carries the `as_of` it
//// answers so a stale reply (after a rail scrub) is dropped against the model's
//// current as-of. `view` renders the month and year-to-date revenue/cost/profit
//// stat trios (the month margin badged on profit) and the per-engineer P&L table.

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
import shared/pnl/view.{type Pnl, type PnlRow} as pnl_view

/// The P&L tab's state: the as-of its data answers (so a stale fetch is dropped)
/// and the load state of the P&L read model.
pub type Model {
  Model(as_of: calendar.Date, pnl: Load)
}

/// The P&L read model's load state.
pub type Load {
  Loading
  Loaded(pnl: Pnl)
  Failed(message: String)
}

/// The tab's messages: the sole message is its own fetch result, carrying the
/// `as_of` it answers.
pub type Msg {
  GotPnl(as_of: calendar.Date, result: Result(Pnl, rsvp.Error(String)))
}

/// Start the tab at `as_of`, kicking off its P&L fetch.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(Model(as_of:, pnl: Loading), fetch(as_of))
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate): the current view
/// stays on screen until the fresh result lands.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, pnl: Loading), fetch(as_of))
}

fn fetch(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/pnl?as_of=" <> time.iso_date(as_of),
    pnl_view.pnl_decoder(),
    GotPnl(as_of, _),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotPnl(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let pnl = case result {
            Ok(pnl) -> Loaded(pnl:)
            Error(error) -> Failed(message: api.describe_error(error))
          }
          #(Model(..model, pnl:), effect.none(), [])
        }
      }
  }
}

/// Render the tab: a loading guard, delegating the loaded render to `panel`.
pub fn view(model: Model) -> Element(Msg) {
  case model.pnl {
    Loading -> ui.empty_state(message: "Loading P&L…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(pnl:) -> panel(pnl, model.as_of)
  }
}

/// Render the P&L for a loaded `pnl` as of `as_of`: two stat trios (this month
/// and year-to-date) and the per-engineer table. Generic over `msg` since it
/// raises none.
pub fn panel(pnl: Pnl, as_of: calendar.Date) -> Element(msg) {
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
