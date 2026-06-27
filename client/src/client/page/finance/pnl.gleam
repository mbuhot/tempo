//// The Finance P&L tab (FR-F*), a self-contained sub-component MVU split out of
//// `client/page/finance`. The tab owns its own `Model` (its as-of, the loaded P&L
//// headline read model, and the per-engineer table host), its own `Msg`, its
//// `init`/`update`, and its `view`.
////
//// The headline stats read `GET /api/pnl?as_of=`; each result carries the `as_of`
//// it answers so a stale reply (after a rail scrub) is dropped against the model's
//// current as-of. `view` renders the month and year-to-date revenue/cost/profit
//// stat trios (the month margin badged on profit), then the per-engineer P&L as the
//// generic data table embedded through `table_host` (which owns the load state,
//// infinite scroll, debounce, and column-layout persistence), reading
//// `GET /api/pnl/table?as_of=&filter.*=&sort=&page_size=&cursor=`. The host's
//// `Activated` outcome raises `Navigate(People(Some(id)))` so the shell opens the
//// engineer's detail.

import client/api
import client/page.{type OutMsg, Navigate}
import client/route
import client/table_host
import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/option.{Some}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp
import shared/money
import shared/pnl/view.{type Pnl} as pnl_view

/// The P&L tab's state: the as-of its data answers (so a stale fetch is dropped),
/// the load state of the headline P&L read model, and the per-engineer table host.
pub type Model {
  Model(as_of: calendar.Date, pnl: Load, host: table_host.Host)
}

/// The headline P&L read model's load state.
pub type Load {
  Loading
  Loaded(pnl: Pnl)
  Failed(message: String)
}

/// The tab's messages: the headline fetch result (carrying the `as_of` it answers)
/// and the embedded table host's sub-messages.
pub type Msg {
  GotPnl(as_of: calendar.Date, result: Result(Pnl, rsvp.Error(String)))
  TableHostMsg(sub: table_host.Msg)
}

/// Start the tab at `as_of`, kicking off its headline fetch and the table host.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.init("/api/pnl/table", as_of)
  #(
    Model(as_of:, pnl: Loading, host:),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate): the current view
/// stays on screen until the fresh result lands.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  #(
    Model(as_of:, pnl: Loading, host:),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
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

    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id:) ->
          case int.parse(id) {
            Ok(engineer_id) -> #(model, effect, [
              Navigate(route.People(id: Some(engineer_id))),
            ])
            Error(Nil) -> #(model, effect, [])
          }
      }
    }
  }
}

/// Render the tab: a loading guard on the headline read, delegating the loaded
/// render to `panel`.
pub fn view(model: Model) -> Element(Msg) {
  case model.pnl {
    Loading -> ui.empty_state(message: "Loading P&L…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(pnl:) -> panel(model, pnl, model.as_of)
  }
}

/// Render the P&L for a loaded `pnl` as of `as_of`: two stat trios (this month and
/// year-to-date) and the per-engineer table embedded via its host.
fn panel(model: Model, pnl: Pnl, as_of: calendar.Date) -> Element(Msg) {
  let month = time.format_month(time.first_of_month(as_of))
  let margin_pct = margin(pnl.month_profit, of: pnl.month_revenue)
  let ytd_margin_pct = margin(pnl.ytd_profit, of: pnl.ytd_revenue)
  let year = int.to_string(time.first_of_month(as_of).year)
  html.div([], [
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(money.to_float(pnl.month_revenue)),
        unit: "/mo",
        label: "Revenue · " <> month,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(pnl.month_cost)),
        unit: "/mo",
        label: "Cost · " <> month,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(pnl.month_profit)),
        unit: "/mo",
        label: "Profit · " <> month,
        pct: margin_pct,
      ),
    ]),
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(money.to_float(pnl.ytd_revenue)),
        unit: "YTD",
        label: "Revenue · since Jan " <> year,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(pnl.ytd_cost)),
        unit: "YTD",
        label: "Cost · since Jan " <> year,
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(pnl.ytd_profit)),
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
        element.map(table_host.view(model.host, "Loading P&L…"), TableHostMsg),
      ],
    ),
  ])
}

/// The month margin badge: `profit / revenue` as a whole percent, or no badge when
/// revenue is zero (avoids a 0%-on-no-revenue reading).
fn margin(profit: money.Money, of revenue: money.Money) -> ui.StatPct {
  case money.to_float(revenue) >. 0.0 {
    True -> ui.Pct(float.round(money.ratio(profit, revenue) *. 100.0))
    False -> ui.NoPct
  }
}
