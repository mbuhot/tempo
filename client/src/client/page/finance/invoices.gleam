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
import client/time
import client/ui
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
import shared/command.{type Event}
import shared/invoice/view.{
  type Invoice, type InvoiceDetail, type InvoiceLine, type InvoicePage,
} as invoice_view
import shared/money
import shared/roster/view.{type Ref, type Roster} as roster_view

/// The Invoices tab's state: the as-of its data answers, the load state of the
/// invoice list, the selected invoice id and its loaded detail, the as-of roster
/// (project `Ref`s for the Draft picker), and the open op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    invoices: Load,
    selected: Option(Int),
    detail: Option(InvoiceDetail),
    roster: Option(Roster),
    op: Option(ui.OpState),
  )
}

/// The invoice list's load state. `Loaded` carries the opaque `next_cursor` from
/// the page response (issue #12) — `Some` when a further keyset page exists — so a
/// later load-more affordance can request it; the first page renders as before.
pub type Load {
  Loading
  Loaded(invoices: List(Invoice), next_cursor: Option(String))
  LoadFailed(message: String)
}

/// The tab's messages: the list / detail / roster fetch results (each carrying the
/// `as_of` it answers), the row/detail navigation actions, the op lifecycle, and
/// the operation reply.
pub type Msg {
  GotInvoices(
    as_of: calendar.Date,
    result: Result(InvoicePage, rsvp.Error(String)),
  )
  GotDetail(
    as_of: calendar.Date,
    id: Int,
    result: Result(InvoiceDetail, rsvp.Error(String)),
  )
  GotRoster(as_of: calendar.Date, result: Result(Roster, rsvp.Error(String)))
  InvoiceClicked(id: Int)
  DetailClosed
  OpOpened(kind: ui.OpKind)
  OpOpenedForInvoice(kind: ui.OpKind, invoice_id: Int)
  OpFieldChanged(field: ui.OpField, value: String)
  OpSubmitted
  OpCancelled
  OpReplied(result: Result(List(Event), rsvp.Error(String)))
}

/// Start the tab at `as_of` with the route-supplied `selected` invoice id: fetch
/// the list and the roster, and (when an invoice is selected) its detail.
pub fn init(
  as_of: calendar.Date,
  selected: Option(Int),
) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      as_of:,
      invoices: Loading,
      selected:,
      detail: None,
      roster: None,
      op: None,
    )
  #(model, fetch_all(as_of, selected))
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate), keeping the open op
/// form and the selected invoice.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let next =
    Model(..model, as_of:, invoices: Loading, detail: None, roster: None)
  #(next, fetch_all(as_of, model.selected))
}

fn fetch_all(as_of: calendar.Date, selected: Option(Int)) -> Effect(Msg) {
  let detail_effect = case selected {
    Some(id) -> fetch_detail(as_of, id)
    None -> effect.none()
  }
  effect.batch([fetch_invoices(as_of), fetch_roster(as_of), detail_effect])
}

fn fetch_invoices(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/invoices?as_of=" <> time.iso_date(as_of),
    invoice_view.invoice_page_decoder(),
    GotInvoices(as_of, _),
  )
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
    GotInvoices(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let invoices = case result {
            Ok(page) ->
              Loaded(invoices: page.invoices, next_cursor: page.next_cursor)
            Error(error) -> LoadFailed(message: api.describe_error(error))
          }
          #(Model(..model, invoices:), effect.none(), [])
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

    InvoiceClicked(id:) -> #(model, effect.none(), [
      Navigate(route.Finance(tab: route.Invoices, invoice: Some(id))),
    ])

    DetailClosed -> #(
      Model(..model, selected: None, detail: None),
      effect.none(),
      [Navigate(route.Finance(tab: route.Invoices, invoice: None))],
    )

    OpOpened(kind:) -> on_op_opened(model, kind, None)

    OpOpenedForInvoice(kind:, invoice_id:) ->
      on_op_opened(model, kind, Some(invoice_id))

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
          let next =
            Model(
              ..model,
              invoices: Loading,
              detail: None,
              roster: None,
              op: None,
            )
          #(next, fetch_all(model.as_of, model.selected), [OperationCommitted])
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
pub fn view(model: Model) -> Element(Msg) {
  let body = case model.invoices {
    Loading -> ui.empty_state(message: "Loading invoices…")
    LoadFailed(message:) -> ui.empty_state(message: message)
    Loaded(invoices:, ..) ->
      case model.detail, model.selected {
        Some(detail_data), Some(_) -> detail(detail_data, invoice_actions())
        _, Some(_) -> ui.empty_state(message: "Loading invoice…")
        _, None -> list(invoices, invoice_actions())
      }
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
fn invoice_actions() -> Actions(Msg) {
  Actions(
    on_draft: OpOpened(ui.OpDraftInvoice),
    on_issue: fn(id) { OpOpenedForInvoice(ui.OpIssueInvoice, id) },
    on_pay: fn(id) { OpOpenedForInvoice(ui.OpPayInvoice, id) },
    on_open: fn(id) { InvoiceClicked(id) },
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
    on_draft: msg,
    on_issue: fn(Int) -> msg,
    on_pay: fn(Int) -> msg,
    on_open: fn(Int) -> msg,
    on_close: msg,
  )
}

/// The invoice list: an outstanding / collected / count stat trio and the invoice
/// table, with a "+ Draft" action. An empty as-of shows an empty-state row.
pub fn list(invoices: List(Invoice), actions: Actions(msg)) -> Element(msg) {
  let outstanding =
    invoices
    |> list.filter(fn(invoice) { invoice.status != "paid" })
    |> list.map(fn(invoice) { invoice.total })
    |> money.sum
  let collected =
    invoices
    |> list.filter(fn(invoice) { invoice.status == "paid" })
    |> list.map(fn(invoice) { invoice.total })
    |> money.sum
  let count = list.length(invoices)
  let rows = case invoices {
    [] -> [
      html.tr([], [
        html.td([attribute.attribute("colspan", "7")], [
          ui.empty_state(message: "No invoices exist yet on this date."),
        ]),
      ]),
    ]
    rows -> list.map(rows, fn(invoice) { invoice_row(invoice, actions) })
  }
  html.div([], [
    html.div([attribute.class("stats stats--cols-3")], [
      ui.stat(
        value: ui.money_k(money.to_float(outstanding)),
        unit: "",
        label: "Outstanding",
        pct: ui.NoPct,
      ),
      ui.stat(
        value: ui.money_k(money.to_float(collected)),
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
      right: [draft_button(actions)],
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
fn invoice_row(invoice: Invoice, actions: Actions(msg)) -> Element(msg) {
  let action = case invoice.status {
    "draft" ->
      html.button(
        [
          attribute.class("btn btn--sm"),
          event.on_click(actions.on_issue(invoice.id))
            |> event.stop_propagation,
        ],
        [html.text("Issue")],
      )
    "issued" ->
      html.button(
        [
          attribute.class("btn btn--sm"),
          event.on_click(actions.on_pay(invoice.id))
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
    [
      attribute.class("clickable"),
      event.on_click(actions.on_open(invoice.id)),
    ],
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
      html.td([attribute.class("num")], [
        html.text(ui.money(money.to_float(invoice.total))),
      ]),
      html.td([], [ui.pill(variant: invoice.status, label: invoice.status)]),
      html.td([attribute.class("num")], [lifecycle]),
    ],
  )
}

/// A Neutral chip naming when a lifecycle transition took effect, e.g.
/// `Issued 5 Feb 2026`. Falls back to the verb alone if the date is somehow
/// absent (a `paid`/`issued` row should always carry its transition date).
fn transition_pill(verb: String, at: Option(calendar.Date)) -> Element(msg) {
  let label = case at {
    Some(date) -> verb <> " " <> time.format_date(date)
    None -> verb
  }
  ui.chip(label: label, tone: ui.Neutral)
}

fn draft_button(actions: Actions(msg)) -> Element(msg) {
  ui.button(
    label: "+ Draft",
    kind: ui.Primary,
    size: ui.Small,
    on_press: actions.on_draft,
  )
}

/// One drilled-in invoice: its metadata, the lifecycle action for its status, and
/// its line items, with a back link to the list.
pub fn detail(detail: InvoiceDetail, actions: Actions(msg)) -> Element(msg) {
  let invoice = detail.invoice
  let action = case invoice.status {
    "draft" ->
      ui.button(
        label: "Issue",
        kind: ui.Primary,
        size: ui.Small,
        on_press: actions.on_issue(invoice.id),
      )
    "issued" ->
      ui.button(
        label: "Mark paid",
        kind: ui.Primary,
        size: ui.Small,
        on_press: actions.on_pay(invoice.id),
      )
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
