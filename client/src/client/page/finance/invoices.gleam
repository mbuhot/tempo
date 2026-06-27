//// The Finance Invoices tab (FR-F*), a self-contained sub-component MVU split out
//// of `client/page/finance`. The tab owns its own `Model` (its as-of, the loaded
//// invoice list, the selected invoice id + its detail, the as-of roster for the
//// Draft project picker, and the open op form), its own `Msg`, its `init`/`update`,
//// and its `view`.
////
//// It reads `GET /api/invoices?as_of=` for the list and, when an invoice is
//// selected (a deep link or a row click), `GET /api/invoices/:id?as_of=` for the
//// detail and `GET /api/roster?as_of=` for the Draft project directory. Each result
//// carries the `as_of` it answers so a stale reply is dropped. Its writes —
//// DraftInvoice / IssueInvoice / PayInvoice — open the contextual op form;
//// submitting posts via `api.submit_operation` and, on success, raises
//// `OperationCommitted` and refetches. Selecting / closing an invoice raises
//// `Navigate` so the shell owns the URL.
////
//// `list` renders the outstanding/collected stat trio and the invoice table (each
//// row's lifecycle cell offering the single action valid for its as-of status);
//// `detail` renders one drilled-in invoice with its lines and the same lifecycle
//// action.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/invoice/view.{type InvoiceDetail, type InvoiceLine} as invoice_view
import shared/money
import shared/roster/view.{type Ref, type Roster} as roster_view

/// The Invoices tab's state: the as-of its data answers, the load state of the
/// invoice list, the selected invoice id and its loaded detail, the as-of roster
/// (project `Ref`s for the Draft picker), and the open op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    host: table_host.Host,
    selected: Option(Int),
    detail: Option(InvoiceDetail),
    roster: Option(Roster),
    op: Option(ui.OpState),
  )
}

/// The tab's messages: the list / detail / roster fetch results (each carrying the
/// `as_of` it answers), the row/detail navigation actions, the op lifecycle, and
/// the operation reply.
pub type Msg {
  TableHostMsg(sub: table_host.Msg)
  GotDetail(
    as_of: calendar.Date,
    id: Int,
    result: Result(InvoiceDetail, rsvp.Error(String)),
  )
  GotRoster(as_of: calendar.Date, result: Result(Roster, rsvp.Error(String)))
  DetailClosed
  OpOpened(permit: ui.Permit)
  OpOpenedForInvoice(permit: ui.Permit, invoice_id: Int)
  OpFieldChanged(field: ui.OpField, value: String)
  OpSubmitted
  OpCancelled
  OpReplied(result: Result(Nil, rsvp.Error(String)))
}

/// Whether the invoice table's first page has loaded — the parent Finance page uses
/// this for its combined loading state.
pub fn loaded(model: Model) -> Bool {
  table_host.is_loaded(model.host)
}

/// The invoice table's load failure, if any, for the Finance page's error banner.
pub fn failure(model: Model) -> Option(String) {
  table_host.failure(model.host)
}

/// Start the tab at `as_of` with the route-supplied `selected` invoice id: fetch
/// the list and the roster, and (when an invoice is selected) its detail.
pub fn init(
  as_of: calendar.Date,
  selected: Option(Int),
) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.init("/api/invoices/table", as_of)
  let model =
    Model(as_of:, host:, selected:, detail: None, roster: None, op: None)
  #(
    model,
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      fetch_side(as_of, selected),
    ]),
  )
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate), keeping the open op
/// form, the selected invoice, and the active filters/sort/layout.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) = table_host.refetch(model.host, as_of)
  let next = Model(..model, as_of:, host:, detail: None, roster: None)
  #(
    next,
    effect.batch([
      effect.map(host_effect, TableHostMsg),
      fetch_side(as_of, model.selected),
    ]),
  )
}

/// The non-table fetches the tab also needs: the as-of roster (for the Draft project
/// picker) and, when an invoice is selected, its detail.
fn fetch_side(as_of: calendar.Date, selected: Option(Int)) -> Effect(Msg) {
  let detail_effect = case selected {
    Some(id) -> fetch_detail(as_of, id)
    None -> effect.none()
  }
  effect.batch([fetch_roster(as_of), detail_effect])
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    GotRoster(as_of, _),
  )
}

fn fetch_detail(as_of: calendar.Date, id: Int) -> Effect(Msg) {
  api.get(
    "/api/invoices/" <> int.to_string(id) <> "?as_of=" <> time.iso_date(as_of),
    invoice_view.invoice_detail_decoder(),
    GotDetail(as_of, id, _),
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id:) ->
          case int.parse(id) {
            Ok(invoice_id) -> #(model, effect, [
              Navigate(route.Finance(
                tab: route.Invoices,
                invoice: Some(invoice_id),
              )),
            ])
            Error(Nil) -> #(model, effect, [])
          }
      }
    }

    GotDetail(as_of:, id:, result:) ->
      case model.as_of == as_of && model.selected == Some(id) {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Ok(detail) -> #(
              Model(..model, detail: Some(detail)),
              effect.none(),
              [],
            )
            Error(_) -> #(model, effect.none(), [])
          }
      }

    GotRoster(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Ok(roster) -> #(
              Model(..model, roster: Some(roster)),
              effect.none(),
              [],
            )
            Error(_) -> #(model, effect.none(), [])
          }
      }

    DetailClosed -> #(
      Model(..model, selected: None, detail: None),
      effect.none(),
      [Navigate(route.Finance(tab: route.Invoices, invoice: None))],
    )

    OpOpened(permit:) -> on_op_opened(model, ui.permit_kind(permit), None)

    OpOpenedForInvoice(permit:, invoice_id:) ->
      on_op_opened(model, ui.permit_kind(permit), Some(invoice_id))

    OpFieldChanged(field:, value:) ->
      case model.op {
        Some(op) -> {
          let form = ui.update_op_form(op.form, field, value)
          #(
            Model(..model, op: Some(ui.OpState(..op, form:))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(op) ->
          case ui.build_command(op.kind, op.form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpReplied),
              [],
            )
            Error(message) -> #(
              Model(..model, op: Some(ui.OpState(..op, error: Some(message)))),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpReplied(result:) ->
      case result {
        Ok(_) -> {
          let #(host, host_effect) = table_host.refetch(model.host, model.as_of)
          let next = Model(..model, host:, detail: None, roster: None, op: None)
          #(
            next,
            effect.batch([
              effect.map(host_effect, TableHostMsg),
              fetch_side(model.as_of, model.selected),
            ]),
            [OperationCommitted],
          )
        }
        Error(error) ->
          case model.op {
            Some(op) -> #(
              Model(
                ..model,
                op: Some(
                  ui.OpState(..op, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
            None -> #(model, effect.none(), [])
          }
      }
  }
}

/// Open an op sheet for `kind`, pre-filling the invoice-id slot when the action was
/// raised from a specific invoice (its row's Issue/Mark-paid button or the detail
/// header) so the presenter does not retype the id.
fn on_op_opened(
  model: Model,
  kind: ui.OpKind,
  invoice_id: Option(Int),
) -> #(Model, Effect(Msg), List(OutMsg)) {
  let blank = ui.blank_op_form(kind:, default_date: model.as_of)
  let filled = case invoice_id {
    Some(id) -> ui.update_op_form(blank, ui.FInvoiceId, int.to_string(id))
    None -> blank
  }
  let form = ui.reconcile_form(filled, [], project_refs(model))
  #(
    Model(..model, op: Some(ui.OpState(kind:, form:, error: None))),
    effect.none(),
    [],
  )
}

/// The project directory for the Draft-invoice `<select>`, from the as-of roster
/// (every active project, id + name). Empty until the roster loads.
fn project_refs(model: Model) -> List(Ref) {
  case model.roster {
    Some(roster) -> roster.projects
    None -> []
  }
}

// --- View -------------------------------------------------------------------

/// Render the tab: its loading guard and the op panel, delegating the list/detail
/// render to `list` / `detail`.
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let actions = invoice_actions(permissions)
  let body = case model.detail, model.selected {
    Some(detail_data), Some(_) -> detail(detail_data, actions)
    _, Some(_) -> ui.empty_state(message: "Loading invoice…")
    _, None -> list_view(model.host, actions)
  }
  html.div([], [op_panel(model), body])
}

/// The open op-form panel, or nothing.
fn op_panel(model: Model) -> Element(Msg) {
  case model.op {
    None -> element.none()
    Some(op) -> view_op_form(model, op)
  }
}

/// The Invoices tab's user actions, mapped onto its own `Msg`: draft / issue / pay
/// open the matching op form, opening a row selects it, closing returns to the list.
fn invoice_actions(permissions: Set(String)) -> Actions(Msg) {
  Actions(
    draft: ui.permit(permissions, own: False, kind: ui.OpDraftInvoice),
    issue: ui.permit(permissions, own: False, kind: ui.OpIssueInvoice),
    pay: ui.permit(permissions, own: False, kind: ui.OpPayInvoice),
    to_open: OpOpened,
    to_open_for: OpOpenedForInvoice,
    on_close: DetailClosed,
  )
}

/// The open op as a centred modal over a dimmed backdrop. Renders the op's fields
/// (the Draft project picker draws from the as-of roster; Issue/Mark-paid show the
/// known invoice id as a locked read-only field), the last rejection line, and a
/// Cancel / verb-labelled Confirm footer.
fn view_op_form(model: Model, op: ui.OpState) -> Element(Msg) {
  ui.modal(
    title: op_title(op.kind),
    error: option.unwrap(op.error, ""),
    body: op_fields(model, op.kind, op.form),
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
    _ -> "Operation"
  }
}

fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpDraftInvoice -> "Draft"
    ui.OpIssueInvoice -> "Issue"
    ui.OpPayInvoice -> "Mark paid"
    _ -> "Confirm"
  }
}

fn op_fields(
  model: Model,
  kind: ui.OpKind,
  form: ui.OpForm,
) -> List(Element(Msg)) {
  case kind {
    ui.OpDraftInvoice -> [
      ui.ref_select(
        label: "Project",
        field: ui.FProjectId,
        refs: project_refs(model),
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
    _ -> []
  }
}

/// The invoice-id field on Issue / Mark-paid: the id is already known from the
/// launching row, so it shows as a disabled read-only `#<id>` rather than an
/// editable input the presenter could break.
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

/// The callbacks the Invoices tab raises, kept as one record so the page wires the
/// tab once: draft a new invoice, issue / pay / open a given invoice by id, and
/// close the open detail back to the list.
pub type Actions(msg) {
  Actions(
    /// Permits to draft / issue / pay (each `invoice.manage`); a launcher renders only
    /// when its permit was granted, so it cannot fire an op the viewer may not run.
    draft: Result(ui.Permit, Nil),
    issue: Result(ui.Permit, Nil),
    pay: Result(ui.Permit, Nil),
    /// Build the page's op-start message from a granted permit.
    to_open: fn(ui.Permit) -> msg,
    to_open_for: fn(ui.Permit, Int) -> msg,
    on_close: msg,
  )
}

/// The invoice list: the generic data table (schema-driven rows, filters, sort,
/// pagination, column layout) wrapped in the Invoices panel with a "+ Draft" action.
/// The table's own messages are mapped onto the tab's `TableMsg`.
fn list_view(host: table_host.Host, actions: Actions(Msg)) -> Element(Msg) {
  ui.panel(title: "Invoices", count: "", right: [draft_button(actions)], body: [
    element.map(table_host.view(host, "Loading invoices…"), TableHostMsg),
  ])
}

fn draft_button(actions: Actions(msg)) -> Element(msg) {
  ui.when_permitted(actions.draft, fn(granted) {
    ui.button(
      label: "+ Draft",
      kind: ui.Primary,
      size: ui.Small,
      on_press: actions.to_open(granted),
    )
  })
}

/// One drilled-in invoice: its metadata, the lifecycle action for its status, and
/// its line items, with a back link to the list.
pub fn detail(detail: InvoiceDetail, actions: Actions(msg)) -> Element(msg) {
  let invoice = detail.invoice
  let action = case invoice.status {
    "draft" ->
      ui.when_permitted(actions.issue, fn(granted) {
        ui.button(
          label: "Issue",
          kind: ui.Primary,
          size: ui.Small,
          on_press: actions.to_open_for(granted, invoice.id),
        )
      })
    "issued" ->
      ui.when_permitted(actions.pay, fn(granted) {
        ui.button(
          label: "Mark paid",
          kind: ui.Primary,
          size: ui.Small,
          on_press: actions.to_open_for(granted, invoice.id),
        )
      })
    _ -> element.none()
  }
  let line_rows = list.map(detail.lines, invoice_line_row)
  html.div([], [
    html.div([attribute.class("back-link"), event.on_click(actions.on_close)], [
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
            ui.kv(
              key: "Total",
              value: ui.money(money.to_float(invoice.total)),
              mono: True,
            ),
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

fn invoice_line_row(line: InvoiceLine) -> Element(msg) {
  html.tr([], [
    html.td([], [html.text(line.engineer)]),
    html.td([], [
      html.span([attribute.class("level-pill")], [
        html.text(ui.level_band(line.level)),
      ]),
    ]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(line.day_rate))),
    ]),
    html.td([attribute.class("num")], [html.text(ui.days(line.days))]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(line.amount))),
    ]),
  ])
}
