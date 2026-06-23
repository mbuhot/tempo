//// The Finance Invoices tab's view (FR-F*), split out of `client/page/finance` so
//// the tab owns its list/detail rendering. The tab raises four user actions —
//// drafting, issuing, paying, opening, and closing an invoice — handed in as
//// labelled callbacks so `view` is generic over the host page's `msg` and never
//// needs to know the page's `Msg` type.
////
//// `list` renders the outstanding/collected stat trio and the invoice table (each
//// row's lifecycle cell offering the single action valid for its as-of status);
//// `detail` renders one drilled-in invoice with its lines and the same lifecycle
//// action. The page owns the loading guard and the op-form panel; this module is
//// pure list/detail presentation.

import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/types.{type Invoice, type InvoiceDetail, type InvoiceLine}

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
    rows -> list.map(rows, fn(invoice) { invoice_row(invoice, actions) })
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
      html.td([attribute.class("num")], [html.text(ui.money(invoice.total))]),
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

fn invoice_line_row(line: InvoiceLine) -> Element(msg) {
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
