//// The Finance page (FR-F*): four tabs (Invoices/Payroll/P&L/Forecast) driven by
//// route.FinanceTab, with the selected invoice id also carried in the route
//// (Finance(tab, invoice)). An incoming Navigate(Finance(Invoices, Some(id)))
//// from Projects selects + loads that invoice's detail with no shell edit.
////
//// Since issue #15 each tab is a self-contained sub-component MVU: it owns its own
//// `Model`, `Msg`, `update`, and `view` under `client/page/finance/<tab>`. This
//// page is the COMPOSITION shell: its `Model` holds the shared rail context (the
//// as-of, the signed-in actor, the active tab) plus one sub-model per tab; its
//// `Msg` wraps each tab's `Msg`; its `update` delegates to the matching tab and
//// re-wraps the effect; its `view` lifts each tab view's messages with
//// `element.map`. The page-level Loading / Failed chrome is derived from the tab
//// sub-states — "Loading finance…" until the first tab's read lands, the Failed
//// banner only when no tab has loaded and one has errored.
////
//// A committed write on one tab (raised as `OperationCommitted`) refetches the
//// OTHER tabs too, so a figure changed on Invoices is reflected on P&L without a
//// shell edit (the writing tab refetches itself). The actor rides on the model
//// because the frozen shell interface passes it only to `init`/`refetch`.

import client/page.{type OutMsg, OperationCommitted}
import client/page/finance/forecast as forecast_tab
import client/page/finance/invoices as invoices_tab
import client/page/finance/payroll as payroll_tab
import client/page/finance/pnl as pnl_tab
import client/route
import client/time
import client/ui
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// --- Model ------------------------------------------------------------------

/// The page state: the shared rail context (as-of, signed-in actor, active tab)
/// and one self-contained sub-model per tab. The page-level Loading / Failed
/// chrome is derived from the tab sub-states rather than stored.
pub type Model {
  Model(
    actor: String,
    as_of: calendar.Date,
    tab: route.FinanceTab,
    invoices: invoices_tab.Model,
    payroll: payroll_tab.Model,
    pnl: pnl_tab.Model,
    forecast: forecast_tab.Model,
  )
}

// --- Msg --------------------------------------------------------------------

/// The page's messages: each tab's `Msg` wrapped in its own constructor, plus the
/// tab-bar click the shell handles directly (a tab switch is internal state, not a
/// route change).
pub type Msg {
  InvoicesMsg(invoices_tab.Msg)
  PayrollMsg(payroll_tab.Msg)
  PnlMsg(pnl_tab.Msg)
  ForecastMsg(forecast_tab.Msg)
  TabClicked(tab: route.FinanceTab)
}

// --- Init / refetch ---------------------------------------------------------

/// Start the page for `route` at `as_of` on the signed-in `actor`'s behalf. The
/// route's `Finance(tab, invoice)` selects the active tab and any deep-linked
/// invoice id, so a cold load of `/finance/pnl` opens on P&L and
/// `/finance/invoices/:id` loads that invoice's detail. A non-Finance route falls
/// back to the Invoices tab.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(tab, selected) = case route {
    route.Finance(tab:, invoice:) -> #(tab, invoice)
    _ -> #(route.Invoices, None)
  }
  let #(invoices, invoices_effect) = invoices_tab.init(as_of, selected)
  let #(payroll, payroll_effect) = payroll_tab.init(as_of)
  let #(pnl, pnl_effect) = pnl_tab.init(as_of)
  let #(forecast, forecast_effect) = forecast_tab.init(as_of)
  let model = Model(actor:, as_of:, tab:, invoices:, payroll:, pnl:, forecast:)
  #(
    model,
    effect.batch([
      effect.map(invoices_effect, InvoicesMsg),
      effect.map(payroll_effect, PayrollMsg),
      effect.map(pnl_effect, PnlMsg),
      effect.map(forecast_effect, ForecastMsg),
    ]),
  )
}

/// Re-fetch every tab's read model for a new `as_of` without dropping the open op
/// form or the selected invoice (stale-while-revalidate). The current view stays on
/// screen until the fresh results arrive and replace it.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(invoices, invoices_effect) = invoices_tab.refetch(model.invoices, as_of)
  let #(payroll, payroll_effect) = payroll_tab.refetch(model.payroll, as_of)
  let #(pnl, pnl_effect) = pnl_tab.refetch(model.pnl, as_of)
  let #(forecast, forecast_effect) = forecast_tab.refetch(model.forecast, as_of)
  let next =
    Model(..model, actor:, as_of:, invoices:, payroll:, pnl:, forecast:)
  #(
    next,
    effect.batch([
      effect.map(invoices_effect, InvoicesMsg),
      effect.map(payroll_effect, PayrollMsg),
      effect.map(pnl_effect, PnlMsg),
      effect.map(forecast_effect, ForecastMsg),
    ]),
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TabClicked(tab:) -> #(Model(..model, tab:), effect.none(), [])

    InvoicesMsg(tab_msg) -> {
      let #(invoices, tab_effect, outs) =
        invoices_tab.update(model.invoices, tab_msg)
      finalize(
        Model(..model, invoices:),
        effect.map(tab_effect, InvoicesMsg),
        outs,
      )
    }

    PayrollMsg(tab_msg) -> {
      let #(payroll, tab_effect, outs) =
        payroll_tab.update(model.payroll, tab_msg)
      finalize(
        Model(..model, payroll:),
        effect.map(tab_effect, PayrollMsg),
        outs,
      )
    }

    PnlMsg(tab_msg) -> {
      let #(pnl, tab_effect, outs) = pnl_tab.update(model.pnl, tab_msg)
      finalize(Model(..model, pnl:), effect.map(tab_effect, PnlMsg), outs)
    }

    ForecastMsg(tab_msg) -> {
      let #(forecast, tab_effect, outs) =
        forecast_tab.update(model.forecast, tab_msg)
      finalize(
        Model(..model, forecast:),
        effect.map(tab_effect, ForecastMsg),
        outs,
      )
    }
  }
}

/// Fold a delegated tab update into the page: when the tab raised
/// `OperationCommitted` (a write landed), refetch the OTHER tabs too so the
/// committed figure is reflected page-wide (the writing tab already refetches
/// itself), batching their effects with the tab's own.
fn finalize(
  model: Model,
  tab_effect: Effect(Msg),
  outs: List(OutMsg),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case list.contains(outs, OperationCommitted) {
    False -> #(model, tab_effect, outs)
    True -> {
      let #(refreshed, refetch_effect) =
        refetch(model, model.as_of, model.actor)
      #(refreshed, effect.batch([tab_effect, refetch_effect]), outs)
    }
  }
}

// --- View -------------------------------------------------------------------

pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  case page_status(model) {
    Failed(message:) ->
      html.div([], [page_head(as_of), ui.empty_state(message: message)])
    PageLoading ->
      html.div([], [
        page_head(as_of),
        ui.empty_state(message: "Loading finance…"),
      ])
    Ready -> view_ready(model, as_of)
  }
}

/// The page-level chrome state, derived from the tab sub-states: `Ready` once any
/// tab has loaded (each tab then shows its own data or per-tab loading guard),
/// `Failed` while no tab has loaded yet but one has errored, otherwise
/// `PageLoading`.
type PageStatus {
  PageLoading
  Ready
  Failed(message: String)
}

fn page_status(model: Model) -> PageStatus {
  case any_loaded(model) {
    True -> Ready
    False ->
      case first_failure(model) {
        Some(message) -> Failed(message:)
        None -> PageLoading
      }
  }
}

fn any_loaded(model: Model) -> Bool {
  invoices_loaded(model.invoices)
  || payroll_loaded(model.payroll)
  || pnl_loaded(model.pnl)
  || forecast_loaded(model.forecast)
}

fn invoices_loaded(model: invoices_tab.Model) -> Bool {
  case model.invoices {
    invoices_tab.Loaded(..) -> True
    _ -> False
  }
}

fn payroll_loaded(model: payroll_tab.Model) -> Bool {
  case model.payroll {
    payroll_tab.Loaded(..) -> True
    _ -> False
  }
}

fn pnl_loaded(model: pnl_tab.Model) -> Bool {
  case model.pnl {
    pnl_tab.Loaded(..) -> True
    _ -> False
  }
}

fn forecast_loaded(model: forecast_tab.Model) -> Bool {
  case model.forecast {
    forecast_tab.Loaded(..) -> True
    _ -> False
  }
}

fn first_failure(model: Model) -> Option(String) {
  let failures =
    option.values([
      invoices_failure(model.invoices),
      payroll_failure(model.payroll),
      pnl_failure(model.pnl),
      forecast_failure(model.forecast),
    ])
  case failures {
    [message, ..] -> Some(message)
    [] -> None
  }
}

fn invoices_failure(model: invoices_tab.Model) -> Option(String) {
  case model.invoices {
    invoices_tab.LoadFailed(message:) -> Some(message)
    _ -> None
  }
}

fn payroll_failure(model: payroll_tab.Model) -> Option(String) {
  case model.payroll {
    payroll_tab.Failed(message:) -> Some(message)
    _ -> None
  }
}

fn pnl_failure(model: pnl_tab.Model) -> Option(String) {
  case model.pnl {
    pnl_tab.Failed(message:) -> Some(message)
    _ -> None
  }
}

fn forecast_failure(model: forecast_tab.Model) -> Option(String) {
  case model.forecast {
    forecast_tab.Failed(message:) -> Some(message)
    _ -> None
  }
}

fn page_head(as_of: calendar.Date) -> Element(Msg) {
  ui.page_head(
    title: "Finance",
    blurb: "Invoices, payroll, and profit — every figure resolved as of "
      <> time.format_date(as_of)
      <> ".",
    actions: [],
  )
}

fn view_ready(model: Model, as_of: calendar.Date) -> Element(Msg) {
  html.div([], [
    page_head(as_of),
    view_tabs(model.tab),
    subpage(
      model.tab == route.Invoices,
      element.map(invoices_tab.view(model.invoices), InvoicesMsg),
    ),
    subpage(
      model.tab == route.Payroll,
      element.map(payroll_tab.view(model.payroll), PayrollMsg),
    ),
    subpage(
      model.tab == route.Pnl,
      element.map(pnl_tab.view(model.pnl), PnlMsg),
    ),
    subpage(
      model.tab == route.Forecast,
      element.map(forecast_tab.view(model.forecast), ForecastMsg),
    ),
  ])
}

fn view_tabs(active: route.FinanceTab) -> Element(Msg) {
  html.div([attribute.class("tabs")], [
    tab_button("Invoices", route.Invoices, active),
    tab_button("Payroll", route.Payroll, active),
    tab_button("P&L", route.Pnl, active),
    tab_button("Forecast", route.Forecast, active),
  ])
}

fn tab_button(
  label: String,
  tab: route.FinanceTab,
  active: route.FinanceTab,
) -> Element(Msg) {
  let class = case tab == active {
    True -> "tabs__tab tabs__tab--active"
    False -> "tabs__tab"
  }
  html.button([attribute.class(class), event.on_click(TabClicked(tab))], [
    html.text(label),
  ])
}

fn subpage(active: Bool, body: Element(Msg)) -> Element(Msg) {
  let class = case active {
    True -> "subpage subpage--active"
    False -> "subpage"
  }
  html.div([attribute.class(class)], [body])
}
