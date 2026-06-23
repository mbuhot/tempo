//// The Finance page (FR-F*): three tabs (Invoices/Payroll/Pnl) driven by
//// route.FinanceTab, with the selected invoice id also carried in the route
//// (Finance(tab, invoice)). An incoming Navigate(Finance(Invoices, Some(id)))
//// from Projects selects + loads that invoice's detail with no shell edit.
//// Writes: DraftInvoice, IssueInvoice, PayInvoice, RunPayroll.
////
//// Reads (all as-of the rail date, except Payroll which uses the month window):
////   * GET /api/invoices?as_of=        -> List(Invoice)
////   * GET /api/invoices/:id?as_of=     -> InvoiceDetail (selected invoice)
////   * GET /api/payroll?from=&to=       -> Payroll (month window of the rail date)
////   * GET /api/pnl?as_of=              -> Pnl
////
//// Each fetch-result message carries the as_of it answers; `update` drops a
//// result whose as_of no longer matches the model's current as_of so a stale
//// reply never clobbers a fresh view or a half-typed op form
//// (stale-while-revalidate). The contextual op form lives on the Invoices and
//// Payroll tabs; submitting it posts a Command via api.submit_operation and, on
//// success, raises OperationCommitted and refetches.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/page/finance/forecast as forecast_tab
import client/page/finance/invoices as invoices_tab
import client/page/finance/payroll as payroll_tab
import client/page/finance/pnl as pnl_tab
import client/route
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/codecs
import shared/types.{
  type Event, type Forecast, type Invoice, type InvoiceDetail, type Payroll,
  type Pnl, type Ref, type Roster,
}

// --- Model ------------------------------------------------------------------

/// The page state. `Loading` until the first read for the current as-of lands;
/// `Loaded` holds every tab's data (each tab fetched independently) plus the
/// selected-invoice detail and the contextual op form; `Failed` carries the
/// first fatal load error. The signed-in `actor` rides on every state because
/// the frozen `update` arity carries no actor, yet `OpSubmitted` must post on
/// the actor's behalf — the shell supplies it through `init`/`refetch`.
pub type Model {
  Loading(
    actor: String,
    as_of: calendar.Date,
    tab: route.FinanceTab,
    selected: Option(Int),
  )
  Loaded(data: Data)
  Failed(actor: String, as_of: calendar.Date, message: String)
}

/// The Loaded data for `as_of`: the signed-in actor, the active tab, the three
/// tab read models (each `Option` until its fetch returns), the selected invoice
/// id and its loaded detail, and the op-form sheet (kind + form + last error)
/// when one is open.
pub type Data {
  Data(
    actor: String,
    as_of: calendar.Date,
    tab: route.FinanceTab,
    invoices: Option(List(Invoice)),
    payroll: Option(Payroll),
    pnl: Option(Pnl),
    forecast: Option(Forecast),
    roster: Option(Roster),
    selected: Option(Int),
    detail: Option(InvoiceDetail),
    op: Option(ui.OpState),
  )
}

// --- Msg --------------------------------------------------------------------

pub type Msg {
  GotInvoices(
    as_of: calendar.Date,
    result: Result(List(Invoice), rsvp.Error(String)),
  )
  GotPayroll(as_of: calendar.Date, result: Result(Payroll, rsvp.Error(String)))
  GotPnl(as_of: calendar.Date, result: Result(Pnl, rsvp.Error(String)))
  GotForecast(
    as_of: calendar.Date,
    result: Result(Forecast, rsvp.Error(String)),
  )
  GotRoster(as_of: calendar.Date, result: Result(Roster, rsvp.Error(String)))
  GotDetail(
    as_of: calendar.Date,
    id: Int,
    result: Result(InvoiceDetail, rsvp.Error(String)),
  )
  TabClicked(tab: route.FinanceTab)
  InvoiceClicked(id: Int)
  DetailClosed
  OpOpened(kind: ui.OpKind)
  OpOpenedForInvoice(kind: ui.OpKind, invoice_id: Int)
  OpFieldChanged(field: ui.OpField, value: String)
  OpSubmitted
  OpCancelled
  OpReplied(result: Result(List(Event), rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Start the page for `route` at `as_of` on the signed-in `actor`'s behalf. The
/// route's `Finance(tab, invoice)` selects the active tab and any deep-linked
/// invoice id, so a cold load of `/finance/pnl` opens on P&L and
/// `/finance/invoices/:id` loads that invoice's detail. A non-Finance route falls
/// back to the Invoices tab. The actor is held on the model so a later
/// `OpSubmitted` can post on its behalf — the frozen `update` arity carries none.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(tab, selected) = case route {
    route.Finance(tab:, invoice:) -> #(tab, invoice)
    _ -> #(route.Invoices, None)
  }
  let model = Loading(actor:, as_of:, tab:, selected:)
  let detail_effect = case selected {
    Some(id) -> fetch_detail(as_of, id)
    None -> effect.none()
  }
  #(model, effect.batch([fetch_all(as_of), detail_effect]))
}

/// Re-fetch every tab's read model for a new `as_of` without dropping the open
/// op form or the selected invoice (stale-while-revalidate). The current view
/// stays on screen until the fresh results arrive and replace it.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(tab, selected, op) = case model {
    Loaded(data) -> #(data.tab, data.selected, data.op)
    Loading(tab:, selected:, ..) -> #(tab, selected, None)
    Failed(..) -> #(route.Invoices, None, None)
  }
  let next =
    Loaded(Data(
      actor: actor,
      as_of:,
      tab:,
      invoices: None,
      payroll: None,
      pnl: None,
      forecast: None,
      roster: None,
      selected:,
      detail: None,
      op:,
    ))
  let detail_effect = case selected {
    Some(id) -> fetch_detail(as_of, id)
    None -> effect.none()
  }
  #(next, effect.batch([fetch_all(as_of), detail_effect]))
}

fn fetch_all(as_of: calendar.Date) -> Effect(Msg) {
  effect.batch([
    fetch_invoices(as_of),
    fetch_payroll(as_of),
    fetch_pnl(as_of),
    fetch_forecast(as_of),
    fetch_roster(as_of),
  ])
}

fn fetch_invoices(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/invoices?as_of=" <> time.iso_date(as_of),
    decode_invoices(),
    GotInvoices(as_of, _),
  )
}

fn fetch_payroll(as_of: calendar.Date) -> Effect(Msg) {
  let from = time.iso_date(time.first_of_month(as_of))
  let to = time.iso_date(time.first_of_next_month(as_of))
  api.get(
    "/api/payroll?from=" <> from <> "&to=" <> to,
    codecs.payroll_decoder(),
    GotPayroll(as_of, _),
  )
}

fn fetch_pnl(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/pnl?as_of=" <> time.iso_date(as_of),
    codecs.pnl_decoder(),
    GotPnl(as_of, _),
  )
}

fn fetch_forecast(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/forecast?as_of=" <> time.iso_date(as_of),
    codecs.forecast_decoder(),
    GotForecast(as_of, _),
  )
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    codecs.roster_decoder(),
    GotRoster(as_of, _),
  )
}

fn fetch_detail(as_of: calendar.Date, id: Int) -> Effect(Msg) {
  api.get(
    "/api/invoices/" <> int.to_string(id) <> "?as_of=" <> time.iso_date(as_of),
    codecs.invoice_detail_decoder(),
    GotDetail(as_of, id, _),
  )
}

fn decode_invoices() -> decode.Decoder(List(Invoice)) {
  decode.list(codecs.invoice_decoder())
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotInvoices(as_of:, result:) -> on_invoices(model, as_of, result)
    GotPayroll(as_of:, result:) -> on_payroll(model, as_of, result)
    GotPnl(as_of:, result:) -> on_pnl(model, as_of, result)
    GotForecast(as_of:, result:) -> on_forecast(model, as_of, result)
    GotRoster(as_of:, result:) -> on_roster(model, as_of, result)
    GotDetail(as_of:, id:, result:) -> on_detail(model, as_of, id, result)
    TabClicked(tab:) -> on_tab(model, tab)
    InvoiceClicked(id:) -> on_invoice_clicked(model, id)
    DetailClosed -> on_detail_closed(model)
    OpOpened(kind:) -> on_op_opened(model, kind, None)
    OpOpenedForInvoice(kind:, invoice_id:) ->
      on_op_opened(model, kind, Some(invoice_id))
    OpFieldChanged(field:, value:) -> on_op_field(model, field, value)
    OpSubmitted -> on_op_submitted(model)
    OpCancelled -> on_op_cancelled(model)
    OpReplied(result:) -> on_op_replied(model, result)
  }
}

fn on_invoices(
  model: Model,
  as_of: calendar.Date,
  result: Result(List(Invoice), rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case answers_current(model, as_of) {
    False -> #(model, effect.none(), [])
    True ->
      case result {
        Ok(invoices) -> #(
          Loaded(Data(..data_for(model, as_of), invoices: Some(invoices))),
          detail_catch_up(model, as_of),
          [],
        )
        Error(error) -> on_load_error(model, error)
      }
  }
}

fn on_payroll(
  model: Model,
  as_of: calendar.Date,
  result: Result(Payroll, rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case answers_current(model, as_of) {
    False -> #(model, effect.none(), [])
    True ->
      case result {
        Ok(payroll) -> #(
          Loaded(Data(..data_for(model, as_of), payroll: Some(payroll))),
          detail_catch_up(model, as_of),
          [],
        )
        Error(error) -> on_load_error(model, error)
      }
  }
}

fn on_pnl(
  model: Model,
  as_of: calendar.Date,
  result: Result(Pnl, rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case answers_current(model, as_of) {
    False -> #(model, effect.none(), [])
    True ->
      case result {
        Ok(pnl) -> #(
          Loaded(Data(..data_for(model, as_of), pnl: Some(pnl))),
          detail_catch_up(model, as_of),
          [],
        )
        Error(error) -> on_load_error(model, error)
      }
  }
}

fn on_forecast(
  model: Model,
  as_of: calendar.Date,
  result: Result(Forecast, rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case answers_current(model, as_of) {
    False -> #(model, effect.none(), [])
    True ->
      case result {
        Ok(forecast) -> #(
          Loaded(Data(..data_for(model, as_of), forecast: Some(forecast))),
          detail_catch_up(model, as_of),
          [],
        )
        Error(error) -> on_load_error(model, error)
      }
  }
}

fn on_roster(
  model: Model,
  as_of: calendar.Date,
  result: Result(Roster, rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case answers_current(model, as_of) {
    False -> #(model, effect.none(), [])
    True ->
      case result {
        Ok(roster) -> #(
          Loaded(Data(..data_for(model, as_of), roster: Some(roster))),
          detail_catch_up(model, as_of),
          [],
        )
        Error(error) -> on_load_error(model, error)
      }
  }
}

/// When the FIRST tab result lands on a deep-linked `Loading` page (transitioning
/// it to `Loaded`), re-issue the selected invoice's detail fetch — so a cold
/// `/finance/invoices/:id` still loads the detail even if the initial detail
/// reply raced ahead of every tab fetch and was dropped while `Loading`. Once
/// already `Loaded`, this is a no-op (the detail is in flight or in hand).
fn detail_catch_up(model: Model, as_of: calendar.Date) -> Effect(Msg) {
  case model {
    Loading(selected: Some(id), ..) -> fetch_detail(as_of, id)
    _ -> effect.none()
  }
}

fn on_detail(
  model: Model,
  as_of: calendar.Date,
  id: Int,
  result: Result(InvoiceDetail, rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) ->
      case data.as_of == as_of && data.selected == Some(id) {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Ok(detail) -> #(
              Loaded(Data(..data, detail: Some(detail))),
              effect.none(),
              [],
            )
            Error(_) -> #(model, effect.none(), [])
          }
      }
    _ -> #(model, effect.none(), [])
  }
}

fn on_tab(
  model: Model,
  tab: route.FinanceTab,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) -> #(Loaded(Data(..data, tab:)), effect.none(), [])
    Loading(actor:, as_of:, selected:, ..) -> #(
      Loading(actor:, as_of:, tab:, selected:),
      effect.none(),
      [],
    )
    Failed(..) -> #(model, effect.none(), [])
  }
}

fn on_invoice_clicked(
  model: Model,
  id: Int,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(..) -> #(model, effect.none(), [
      Navigate(route.Finance(tab: route.Invoices, invoice: Some(id))),
    ])
    _ -> #(model, effect.none(), [])
  }
}

fn on_detail_closed(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) -> #(
      Loaded(Data(..data, selected: None, detail: None)),
      effect.none(),
      [Navigate(route.Finance(tab: route.Invoices, invoice: None))],
    )
    _ -> #(model, effect.none(), [])
  }
}

/// Open an op sheet for `kind`, pre-filling the invoice-id slot when the action
/// was raised from a specific invoice (its row's Issue/Mark-paid button or the
/// detail header) so the presenter does not retype the id.
fn on_op_opened(
  model: Model,
  kind: ui.OpKind,
  invoice_id: Option(Int),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) -> {
      let blank = ui.blank_op_form(kind:, default_date: data.as_of)
      let filled = case invoice_id {
        Some(id) -> ui.update_op_form(blank, ui.FInvoiceId, int.to_string(id))
        None -> blank
      }
      let form = ui.reconcile_form(filled, [], project_refs(data))
      #(
        Loaded(Data(..data, op: Some(ui.OpState(kind:, form:, error: None)))),
        effect.none(),
        [],
      )
    }
    _ -> #(model, effect.none(), [])
  }
}

fn on_op_field(
  model: Model,
  field: ui.OpField,
  value: String,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(Data(op: Some(op), ..) as data) -> {
      let form = ui.update_op_form(op.form, field, value)
      #(
        Loaded(Data(..data, op: Some(ui.OpState(..op, form:)))),
        effect.none(),
        [],
      )
    }
    _ -> #(model, effect.none(), [])
  }
}

fn on_op_submitted(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(Data(op: Some(op), ..) as data) ->
      case ui.build_command(op.kind, op.form) {
        Ok(command) -> #(model, api.submit_operation(command, OpReplied), [])
        Error(message) -> #(
          Loaded(Data(..data, op: Some(ui.OpState(..op, error: Some(message))))),
          effect.none(),
          [],
        )
      }
    _ -> #(model, effect.none(), [])
  }
}

fn on_op_cancelled(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) -> #(Loaded(Data(..data, op: None)), effect.none(), [])
    _ -> #(model, effect.none(), [])
  }
}

fn on_op_replied(
  model: Model,
  result: Result(List(Event), rsvp.Error(String)),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loaded(data) ->
      case result {
        Ok(_) -> {
          let #(next, fetch) = refetch_loaded(data)
          #(next, fetch, [OperationCommitted])
        }
        Error(error) ->
          case data.op {
            Some(op) -> #(
              Loaded(
                Data(
                  ..data,
                  op: Some(
                    ui.OpState(..op, error: Some(api.describe_error(error))),
                  ),
                ),
              ),
              effect.none(),
              [],
            )
            None -> #(model, effect.none(), [])
          }
      }
    _ -> #(model, effect.none(), [])
  }
}

/// Re-run every tab fetch after a committed write, closing the op sheet and
/// reloading the selected invoice if one is open.
fn refetch_loaded(data: Data) -> #(Model, Effect(Msg)) {
  let next =
    Loaded(
      Data(
        ..data,
        invoices: None,
        payroll: None,
        pnl: None,
        forecast: None,
        roster: None,
        detail: None,
        op: None,
      ),
    )
  let detail_effect = case data.selected {
    Some(id) -> fetch_detail(data.as_of, id)
    None -> effect.none()
  }
  #(next, effect.batch([fetch_all(data.as_of), detail_effect]))
}

// --- Update helpers ---------------------------------------------------------

/// Whether a fetch result for `as_of` still answers the model's current as-of.
/// A reply for a stale instant is dropped so it never clobbers a fresh view or a
/// half-typed op form.
fn answers_current(model: Model, as_of: calendar.Date) -> Bool {
  model_as_of(model) == as_of
}

fn model_as_of(model: Model) -> calendar.Date {
  case model {
    Loading(as_of:, ..) -> as_of
    Loaded(data) -> data.as_of
    Failed(as_of:, ..) -> as_of
  }
}

/// The `Data` to fold a fresh tab result into: the existing `Loaded` data when
/// present, otherwise a blank `Data` for the current as-of carrying over the
/// `Loading`/`Failed` tab + selection + actor so the first result transitions to
/// `Loaded` without losing route-driven context.
fn data_for(model: Model, as_of: calendar.Date) -> Data {
  case model {
    Loaded(data) -> data
    Loading(actor:, tab:, selected:, ..) ->
      blank_data(actor, as_of, tab, selected)
    Failed(actor:, ..) -> blank_data(actor, as_of, route.Invoices, None)
  }
}

fn blank_data(
  actor: String,
  as_of: calendar.Date,
  tab: route.FinanceTab,
  selected: Option(Int),
) -> Data {
  Data(
    actor:,
    as_of:,
    tab:,
    invoices: None,
    payroll: None,
    pnl: None,
    forecast: None,
    roster: None,
    selected:,
    detail: None,
    op: None,
  )
}

/// Fold a fatal load error: surface it as `Failed` only while the page has not
/// yet rendered any data (a `Loading` state); once `Loaded`, a single failed
/// tab fetch is ignored so the rest of the page stays usable.
fn on_load_error(
  model: Model,
  error: rsvp.Error(String),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model {
    Loading(actor:, as_of:, ..) -> #(
      Failed(actor:, as_of:, message: api.describe_error(error)),
      effect.none(),
      [],
    )
    _ -> #(model, effect.none(), [])
  }
}

// --- View -------------------------------------------------------------------

pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  case model {
    Failed(message:, ..) ->
      html.div([], [page_head(as_of), ui.empty_state(message: message)])
    Loading(..) ->
      html.div([], [
        page_head(as_of),
        ui.empty_state(message: "Loading finance…"),
      ])
    Loaded(data) -> view_loaded(data, as_of)
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

fn view_loaded(data: Data, as_of: calendar.Date) -> Element(Msg) {
  html.div([], [
    page_head(as_of),
    view_tabs(data.tab),
    subpage(data.tab == route.Invoices, view_invoices(data)),
    subpage(data.tab == route.Payroll, view_payroll(data)),
    subpage(data.tab == route.Pnl, view_pnl(data)),
    subpage(data.tab == route.Forecast, view_forecast(data)),
  ])
}

/// The open op-form panel for the active tab, or nothing. Each tab only shows
/// the op forms whose writes belong to it (Invoices: Draft/Issue/Pay; Payroll:
/// RunPayroll; P&L: none) so a sheet opened on one tab does not bleed onto
/// another.
fn op_panel(data: Data, tab: route.FinanceTab) -> Element(Msg) {
  case data.op {
    Some(op) ->
      case op_tab(op.kind) == Some(tab) {
        True -> view_op_form(data, op)
        False -> element.none()
      }
    None -> element.none()
  }
}

/// The finance tab a contextual op belongs to, or `None` for an op this page
/// does not host.
fn op_tab(kind: ui.OpKind) -> Option(route.FinanceTab) {
  case kind {
    ui.OpDraftInvoice -> Some(route.Invoices)
    ui.OpIssueInvoice -> Some(route.Invoices)
    ui.OpPayInvoice -> Some(route.Invoices)
    ui.OpRunPayroll -> Some(route.Payroll)
    _ -> None
  }
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

// --- Invoices tab -----------------------------------------------------------

/// The Invoices tab: its loading guard and the shared op-panel, delegating the
/// list/detail render to the tab's own `page/finance/invoices` module. The tab's
/// user actions are wired from this page's `Msg` constructors into the module's
/// `Actions` record.
fn view_invoices(data: Data) -> Element(Msg) {
  let body = case data.invoices {
    None -> ui.empty_state(message: "Loading invoices…")
    Some(invoices) ->
      case data.detail, data.selected {
        Some(detail), Some(_) -> invoices_tab.detail(detail, invoice_actions())
        _, Some(_) -> ui.empty_state(message: "Loading invoice…")
        _, None -> invoices_tab.list(invoices, invoice_actions())
      }
  }
  html.div([], [op_panel(data, route.Invoices), body])
}

/// The Invoices tab's user actions, mapped onto this page's `Msg`: draft / issue /
/// pay open the matching op form, opening a row selects it, closing returns to the
/// list.
fn invoice_actions() -> invoices_tab.Actions(Msg) {
  invoices_tab.Actions(
    on_draft: OpOpened(ui.OpDraftInvoice),
    on_issue: fn(id) { OpOpenedForInvoice(ui.OpIssueInvoice, id) },
    on_pay: fn(id) { OpOpenedForInvoice(ui.OpPayInvoice, id) },
    on_open: fn(id) { InvoiceClicked(id) },
    on_close: DetailClosed,
  )
}

// --- Payroll tab ------------------------------------------------------------

/// The month's payroll panel, adaptive across three states off the `run` /
/// preview-vs-paid reconciliation:
///   * no materialized run  -> a live PREVIEW of what would be paid, with the run
///     button;
///   * a run whose paid lines equal the live recompute -> RECONCILED, no button
///     (the DB refuses a re-run);
///   * a run a back-dated fact has since outgrown -> VARIANCE, the per-line Δ and
///     the total back-pay owed.
/// The Payroll tab: its loading guard and the shared op-panel, delegating the
/// loaded render to the tab's own `page/finance/payroll` module. The run-payroll
/// button raises `OpOpened(ui.OpRunPayroll)`, handed in as the tab's one action.
fn view_payroll(data: Data) -> Element(Msg) {
  let body = case data.payroll {
    None -> ui.empty_state(message: "Loading payroll…")
    Some(payroll) ->
      payroll_tab.view(payroll, on_run: OpOpened(ui.OpRunPayroll))
  }
  html.div([], [op_panel(data, route.Payroll), body])
}

// --- P&L tab ----------------------------------------------------------------

/// The P&L tab: its loading guard, delegating the loaded render to the tab's own
/// `page/finance/pnl` module.
fn view_pnl(data: Data) -> Element(Msg) {
  case data.pnl {
    None -> ui.empty_state(message: "Loading P&L…")
    Some(pnl) -> pnl_tab.view(pnl, data.as_of)
  }
}

// --- Forecast tab -----------------------------------------------------------

/// The Forecast tab: its loading guard, delegating the loaded render to the tab's
/// own `page/finance/forecast` module.
fn view_forecast(data: Data) -> Element(Msg) {
  case data.forecast {
    None -> ui.empty_state(message: "Loading forecast…")
    Some(forecast) -> forecast_tab.view(forecast)
  }
}

// --- Op form sheet ----------------------------------------------------------

/// The open op as a centred modal over a dimmed backdrop. Renders the op's fields
/// (the Draft project picker draws from the as-of roster; Issue/Mark-paid show the
/// known invoice id as a locked read-only field; Run payroll is period dates), the
/// last rejection line, and a Cancel / verb-labelled Confirm footer. Clicking the
/// backdrop or Cancel raises `OpCancelled`; Confirm raises `OpSubmitted`.
fn view_op_form(data: Data, op: ui.OpState) -> Element(Msg) {
  ui.modal(
    title: op_title(op.kind),
    error: option.unwrap(op.error, ""),
    body: op_fields(data, op.kind, op.form),
    on_cancel: OpCancelled,
    on_confirm: OpSubmitted,
    confirm_label: op_verb(op.kind),
  )
}

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpDraftInvoice -> "Draft an invoice"
    ui.OpIssueInvoice -> "Issue invoice"
    ui.OpPayInvoice -> "Mark invoice paid"
    ui.OpRunPayroll -> "Run payroll"
    _ -> "Operation"
  }
}

fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpDraftInvoice -> "Draft"
    ui.OpIssueInvoice -> "Issue"
    ui.OpPayInvoice -> "Mark paid"
    ui.OpRunPayroll -> "Run payroll"
    _ -> "Confirm"
  }
}

fn op_fields(
  data: Data,
  kind: ui.OpKind,
  form: ui.OpForm,
) -> List(Element(Msg)) {
  case kind {
    ui.OpDraftInvoice -> [
      ui.ref_select(
        label: "Project",
        field: ui.FProjectId,
        refs: project_refs(data),
        selected: form.project_id,
        to_msg: OpFieldChanged,
      ),
      ui.op_field(
        label: "Billing from",
        field: ui.FValidFrom,
        value: form.valid_from,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
      ui.op_field(
        label: "Billing to",
        field: ui.FValidTo,
        value: form.valid_to,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
    ]
    ui.OpIssueInvoice -> [
      locked_invoice_field(form.invoice_id),
      ui.op_field(
        label: "Date",
        field: ui.FEffective,
        value: form.effective,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
    ]
    ui.OpPayInvoice -> [
      locked_invoice_field(form.invoice_id),
      ui.op_field(
        label: "Date",
        field: ui.FEffective,
        value: form.effective,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
    ]
    ui.OpRunPayroll -> [
      ui.op_field(
        label: "Period from",
        field: ui.FValidFrom,
        value: form.valid_from,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
      ui.op_field(
        label: "Period to",
        field: ui.FValidTo,
        value: form.valid_to,
        input_type: "date",
        to_msg: OpFieldChanged,
      ),
    ]
    _ -> []
  }
}

/// The invoice-id field on Issue / Mark-paid: the id is already known from the
/// launching row, so it shows as a disabled read-only `#<id>` rather than an
/// editable input the presenter could break. No `event` binding, so it stays in
/// the slot `OpOpenedForInvoice` pre-filled.
fn locked_invoice_field(invoice_id: String) -> Element(Msg) {
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Invoice")]),
    html.input([
      attribute.type_("text"),
      attribute.attribute("aria-label", "Invoice"),
      attribute.value("#" <> invoice_id),
      attribute.readonly(True),
      attribute.disabled(True),
    ]),
  ])
}

// --- Directories (Ref lists for op selects) ---------------------------------

/// The project directory for the Draft-invoice `<select>`, from the as-of roster
/// (every active project, id + name). Empty until the roster loads, so the select
/// renders an inert "Loading…" placeholder.
fn project_refs(data: Data) -> List(Ref) {
  case data.roster {
    Some(roster) -> roster.projects
    None -> []
  }
}
