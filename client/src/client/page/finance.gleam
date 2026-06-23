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
import client/route
import client/time
import client/ui
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
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
  type Event, type Forecast, type ForecastMonth, type Invoice,
  type InvoiceDetail, type InvoiceLine, type Payroll, type PayrollLine, type Pnl,
  type PnlRow, type Ref, type Roster,
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

fn view_invoices(data: Data) -> Element(Msg) {
  let body = case data.invoices {
    None -> ui.empty_state(message: "Loading invoices…")
    Some(invoices) ->
      case data.detail, data.selected {
        Some(detail), Some(_) -> view_invoice_detail(detail)
        _, Some(_) -> ui.empty_state(message: "Loading invoice…")
        _, None -> view_invoice_list(invoices)
      }
  }
  html.div([], [op_panel(data, route.Invoices), body])
}

fn view_invoice_list(invoices: List(Invoice)) -> Element(Msg) {
  let outstanding =
    invoices
    |> list.filter(fn(invoice) { invoice.status != "paid" })
    |> list.fold(0.0, fn(sum, invoice) { sum +. invoice.total })
  let collected =
    invoices
    |> list.filter(fn(invoice) { invoice.status == "paid" })
    |> list.fold(0.0, fn(sum, invoice) { sum +. invoice.total })
  let count = list.length(invoices)
  let rows = case invoices {
    [] -> [
      html.tr([], [
        html.td([attribute.attribute("colspan", "7")], [
          ui.empty_state(message: "No invoices exist yet on this date."),
        ]),
      ]),
    ]
    rows -> list.map(rows, invoice_row)
  }
  html.div([], [
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(outstanding),
        unit: "",
        label: "Outstanding",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(collected),
        unit: "",
        label: "Collected (visible)",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: int.to_string(count),
        unit: "invoices",
        label: "Exist as of date",
        pct: ui.NoPct,
      ),
    ]),
    ui.panel(
      title: "Invoices",
      count: int.to_string(count),
      right: [draft_button()],
      body: [
        ui.data_table(
          headers: [
            #("Invoice", False),
            #("Project", False),
            #("Client", False),
            #("Month", False),
            #("Total", True),
            #("Status", False),
            #("", True),
          ],
          rows: rows,
        ),
      ],
    ),
  ])
}

/// The row's lifecycle cell: the single action VALID for the row's current as-of
/// status (a `draft` offers Issue, an `issued` offers Mark paid, a `paid` offers
/// nothing) and, where a transition has already happened, a Neutral chip stating
/// when it took effect (`Issued <date>` on an issued/paid row, `Paid <date>` on a
/// paid row). The action stays a raw `html.button` so the row click can be
/// stopped from propagating (the `ui.button` primitive carries no such handle).
fn invoice_row(invoice: Invoice) -> Element(Msg) {
  let action = case invoice.status {
    "draft" ->
      html.button(
        [
          attribute.class("btn btn--sm"),
          event.on_click(OpOpenedForInvoice(ui.OpIssueInvoice, invoice.id))
            |> event.stop_propagation,
        ],
        [html.text("Issue")],
      )
    "issued" ->
      html.button(
        [
          attribute.class("btn btn--sm"),
          event.on_click(OpOpenedForInvoice(ui.OpPayInvoice, invoice.id))
            |> event.stop_propagation,
        ],
        [html.text("Mark paid")],
      )
    _ -> element.none()
  }
  let lifecycle = case invoice.status {
    "draft" -> action
    "issued" ->
      html.div([attribute.class("action-row")], [
        transition_pill("Issued", invoice.issued_at),
        action,
      ])
    "paid" -> transition_pill("Paid", invoice.paid_at)
    _ -> element.none()
  }
  html.tr(
    [attribute.class("clickable"), event.on_click(InvoiceClicked(invoice.id))],
    [
      html.td([attribute.class("mono")], [
        html.text("#" <> int.to_string(invoice.id)),
      ]),
      html.td([], [
        ui.swatch(category: invoice.id, inline: True),
        html.text(invoice.project),
      ]),
      html.td([], [html.text(invoice.client)]),
      html.td([], [html.text(time.format_month(invoice.billing_from))]),
      html.td([attribute.class("num")], [html.text(ui.money(invoice.total))]),
      html.td([], [ui.pill(variant: invoice.status, label: invoice.status)]),
      html.td([attribute.class("num")], [lifecycle]),
    ],
  )
}

/// A Neutral chip naming when a lifecycle transition took effect, e.g.
/// `Issued 5 Feb 2026`. Falls back to the verb alone if the date is somehow
/// absent (a `paid`/`issued` row should always carry its transition date).
fn transition_pill(verb: String, at: Option(calendar.Date)) -> Element(Msg) {
  let label = case at {
    Some(date) -> verb <> " " <> time.format_date(date)
    None -> verb
  }
  ui.chip(label: label, tone: ui.Neutral)
}

fn draft_button() -> Element(Msg) {
  ui.button(
    label: "+ Draft",
    kind: ui.Primary,
    size: ui.Small,
    on_press: OpOpened(ui.OpDraftInvoice),
  )
}

fn view_invoice_detail(detail: InvoiceDetail) -> Element(Msg) {
  let invoice = detail.invoice
  let action = case invoice.status {
    "draft" ->
      ui.button(
        label: "Issue",
        kind: ui.Primary,
        size: ui.Small,
        on_press: OpOpenedForInvoice(ui.OpIssueInvoice, invoice.id),
      )
    "issued" ->
      ui.button(
        label: "Mark paid",
        kind: ui.Primary,
        size: ui.Small,
        on_press: OpOpenedForInvoice(ui.OpPayInvoice, invoice.id),
      )
    _ -> element.none()
  }
  let line_rows = list.map(detail.lines, invoice_line_row)
  html.div([], [
    html.div([attribute.class("back-link"), event.on_click(DetailClosed)], [
      html.text("‹ All invoices"),
    ]),
    ui.panel(
      title: "Invoice #" <> int.to_string(invoice.id),
      count: invoice.status,
      right: [action],
      body: [
        html.div([attribute.class("pad-detail")], [
          html.div([attribute.class("kv")], [
            ui.kv(key: "Project", value: invoice.project, mono: False),
            ui.kv(key: "Client", value: invoice.client, mono: False),
            ui.kv(
              key: "Month",
              value: time.format_month(invoice.billing_from),
              mono: False,
            ),
            ui.kv(key: "Total", value: ui.money(invoice.total), mono: True),
          ]),
        ]),
      ],
    ),
    ui.panel(
      title: "Lines",
      count: int.to_string(list.length(detail.lines)),
      right: [],
      body: [
        ui.data_table(
          headers: [
            #("Engineer", False),
            #("Level", False),
            #("Day rate", True),
            #("Days", True),
            #("Amount", True),
          ],
          rows: line_rows,
        ),
      ],
    ),
  ])
}

fn invoice_line_row(line: InvoiceLine) -> Element(Msg) {
  html.tr([], [
    html.td([], [html.text(line.engineer)]),
    html.td([], [
      html.span([attribute.class("level-pill")], [
        html.text(ui.level_band(line.level)),
      ]),
    ]),
    html.td([attribute.class("num")], [html.text(ui.money(line.day_rate))]),
    html.td([attribute.class("num")], [html.text(ui.days(line.days))]),
    html.td([attribute.class("num")], [html.text(ui.money(line.amount))]),
  ])
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
fn view_payroll(data: Data) -> Element(Msg) {
  let body = case data.payroll {
    None -> ui.empty_state(message: "Loading payroll…")
    Some(payroll) ->
      case payroll.run {
        None -> view_payroll_preview(payroll)
        Some(_) ->
          case payroll_reconciled(payroll.lines) {
            True -> view_payroll_reconciled(payroll)
            False -> view_payroll_variance(payroll)
          }
      }
  }
  html.div([], [op_panel(data, route.Payroll), body])
}

/// Whether every line's frozen paid amount still equals the live recompute (within
/// a sub-cent epsilon) — i.e. nothing has been back-dated since the run. A line
/// with no paid amount (employed-but-not-in-run) counts as a variance.
fn payroll_reconciled(lines: List(PayrollLine)) -> Bool {
  list.all(lines, fn(line) {
    case line.paid_amount {
      Some(paid) -> float.absolute_value(line.preview_amount -. paid) <. 0.005
      None -> False
    }
  })
}

/// NOT YET RUN: the live recompute over current facts, the count of employed
/// engineers, the total to pay, and the run button.
fn view_payroll_preview(payroll: Payroll) -> Element(Msg) {
  let month = time.format_month(payroll.period_from)
  let count = list.length(payroll.lines)
  let total =
    list.fold(payroll.lines, 0.0, fn(sum, line) { sum +. line.preview_amount })
  let run_button =
    ui.button(
      label: "Run payroll",
      kind: ui.Primary,
      size: ui.Small,
      on_press: OpOpened(ui.OpRunPayroll),
    )
  ui.panel(
    title: "Payroll preview · " <> month,
    count: int.to_string(count) <> " employed · not yet run",
    right: [
      html.span([attribute.class("finance__total-note")], [
        html.text(ui.money(total) <> " to pay"),
      ]),
      run_button,
    ],
    body: [
      ui.data_table(
        headers: [#("Engineer", False), #("Days", True), #("Preview", True)],
        rows: list.map(payroll.lines, payroll_preview_row),
      ),
    ],
  )
}

fn payroll_preview_row(line: PayrollLine) -> Element(Msg) {
  html.tr([], [
    html.td([], [html.text(line.engineer)]),
    html.td([attribute.class("num")], [html.text(ui.days(line.preview_days))]),
    html.td([attribute.class("num")], [
      html.text(ui.money(line.preview_amount)),
    ]),
  ])
}

/// RUN, NO CHANGES: the frozen paid lines, reconciled against the live recompute.
/// No run button — the DB refuses a second run for the same month.
fn view_payroll_reconciled(payroll: Payroll) -> Element(Msg) {
  let month = time.format_month(payroll.period_from)
  let count = list.length(payroll.lines)
  let total =
    list.fold(payroll.lines, 0.0, fn(sum, line) {
      sum +. option.unwrap(line.paid_amount, 0.0)
    })
  ui.panel(
    title: "Payroll run · " <> month,
    count: int.to_string(count) <> " employed · reconciled",
    right: [
      html.span([attribute.class("finance__total-note")], [
        html.text(ui.money(total) <> " paid"),
      ]),
    ],
    body: [
      ui.data_table(
        headers: [#("Engineer", False), #("Days", True), #("Paid", True)],
        rows: list.map(payroll.lines, payroll_paid_row),
      ),
    ],
  )
}

fn payroll_paid_row(line: PayrollLine) -> Element(Msg) {
  html.tr([], [
    html.td([], [html.text(line.engineer)]),
    html.td([attribute.class("num")], [
      html.text(ui.days(option.unwrap(line.paid_days, 0.0))),
    ]),
    html.td([attribute.class("num")], [
      html.text(ui.money(option.unwrap(line.paid_amount, 0.0))),
    ]),
  ])
}

/// RUN + VARIANCE: a fact was back-dated into the month after the run, so the live
/// recompute ("should be") no longer matches the frozen paid line for some
/// engineer. The header warns of the total back-pay owed; the table shows paid vs
/// should-be with the per-line Δ, the varying rows flagged.
fn view_payroll_variance(payroll: Payroll) -> Element(Msg) {
  let month = time.format_month(payroll.period_from)
  let owed =
    list.fold(payroll.lines, 0.0, fn(sum, line) { sum +. line_delta(line) })
  ui.panel(
    title: "Payroll run · " <> month,
    count: "",
    right: [
      html.span([attribute.class("finance__owed")], [
        html.text("⚠ " <> ui.money(owed) <> " back-pay owed"),
      ]),
    ],
    body: [
      ui.data_table(
        headers: [
          #("Engineer", False),
          #("Paid", True),
          #("Should be", True),
          #("Δ", True),
        ],
        rows: list.map(payroll.lines, payroll_variance_row),
      ),
    ],
  )
}

/// The back-pay Δ for a line: the live recompute minus the frozen paid amount (a
/// not-yet-paid line owes its full preview).
fn line_delta(line: PayrollLine) -> Float {
  line.preview_amount -. option.unwrap(line.paid_amount, 0.0)
}

fn payroll_variance_row(line: PayrollLine) -> Element(Msg) {
  let delta = line_delta(line)
  let varies = float.absolute_value(delta) >=. 0.005
  let row_class = case varies {
    True -> "finance__variance-row"
    False -> ""
  }
  let delta_text = case varies {
    True -> ui.money(delta)
    False -> "—"
  }
  let delta_class = case varies {
    True -> "num finance__owed"
    False -> "num"
  }
  html.tr([attribute.class(row_class)], [
    html.td([], [html.text(line.engineer)]),
    html.td([attribute.class("num")], [
      html.text(ui.money(option.unwrap(line.paid_amount, 0.0))),
    ]),
    html.td([attribute.class("num")], [
      html.text(ui.money(line.preview_amount)),
    ]),
    html.td([attribute.class(delta_class)], [html.text(delta_text)]),
  ])
}

// --- P&L tab ----------------------------------------------------------------

fn view_pnl(data: Data) -> Element(Msg) {
  case data.pnl {
    None -> ui.empty_state(message: "Loading P&L…")
    Some(pnl) -> {
      let month = time.format_month(time.first_of_month(data.as_of))
      let margin_pct = case pnl.month_revenue >. 0.0 {
        True ->
          ui.Pct(float.round(pnl.month_profit /. pnl.month_revenue *. 100.0))
        False -> ui.NoPct
      }
      let ytd_margin_pct = case pnl.ytd_revenue >. 0.0 {
        True -> ui.Pct(float.round(pnl.ytd_profit /. pnl.ytd_revenue *. 100.0))
        False -> ui.NoPct
      }
      let year = int.to_string(time.first_of_month(data.as_of).year)
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
  }
}

fn pnl_row(row: PnlRow) -> Element(Msg) {
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

// --- Forecast tab -----------------------------------------------------------

/// The forward P&L from committed demand (`GET /api/forecast?as_of=`): one row per
/// calendar month from the as-of month to the cliff (Month | Revenue | Cost |
/// Profit | Margin), capped by a total row summing each money column with the
/// blended margin. An empty-state when no month carries demand.
fn view_forecast(data: Data) -> Element(Msg) {
  case data.forecast {
    None -> ui.empty_state(message: "Loading forecast…")
    Some(forecast) ->
      case forecast.months {
        [] ->
          ui.panel(title: "Forecast", count: "0 months", right: [], body: [
            ui.empty_state(
              message: "No committed demand to forecast on this date.",
            ),
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
}

fn forecast_row(month: ForecastMonth) -> Element(Msg) {
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
) -> Element(Msg) {
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
