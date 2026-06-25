//// The Finance Payroll tab's view (FR-F*), split out of `client/page/finance` so
//// the tab owns its own rendering. The tab raises a single message — pressing
//// "Run payroll" — so `view` is generic over the host page's `msg` and takes that
//// one action as the labelled `on_run` argument; every other cell is a pure table.
////
//// `view` is adaptive across three states off the `run` / preview-vs-paid
//// reconciliation:
////   * no materialized run  -> a live PREVIEW of what would be paid, with the run
////     button;
////   * a run whose paid lines equal the live recompute -> RECONCILED, no button
////     (the DB refuses a re-run);
////   * a run a back-dated fact has since outgrown -> VARIANCE, the per-line Δ and
////     the total back-pay owed.

import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import shared/payroll/view.{type Payroll, type PayrollLine}

/// Render the Payroll tab for a loaded `payroll`, choosing the preview / reconciled
/// / variance presentation from the run state. `on_run` is dispatched when the
/// preview's "Run payroll" button is pressed (the tab's only message).
pub fn view(payroll: Payroll, on_run on_run: msg) -> Element(msg) {
  case payroll.run {
    None -> view_preview(payroll, on_run)
    Some(_) ->
      case reconciled(payroll.lines) {
        True -> view_reconciled(payroll)
        False -> view_variance(payroll)
      }
  }
}

/// Whether every line's frozen paid amount still equals the live recompute (within
/// a sub-cent epsilon) — i.e. nothing has been back-dated since the run. A line
/// with no paid amount (employed-but-not-in-run) counts as a variance.
pub fn reconciled(lines: List(PayrollLine)) -> Bool {
  list.all(lines, fn(line) {
    case line.paid_amount {
      Some(paid) -> float.absolute_value(line.preview_amount -. paid) <. 0.005
      None -> False
    }
  })
}

/// NOT YET RUN: the live recompute over current facts, the count of employed
/// engineers, the total to pay, and the run button.
fn view_preview(payroll: Payroll, on_run: msg) -> Element(msg) {
  let month = time.format_month(payroll.period_from)
  let count = list.length(payroll.lines)
  let total =
    list.fold(payroll.lines, 0.0, fn(sum, line) { sum +. line.preview_amount })
  let run_button =
    ui.button(
      label: "Run payroll",
      kind: ui.Primary,
      size: ui.Small,
      on_press: on_run,
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
        rows: list.map(payroll.lines, preview_row),
      ),
    ],
  )
}

fn preview_row(line: PayrollLine) -> Element(msg) {
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
fn view_reconciled(payroll: Payroll) -> Element(msg) {
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
        rows: list.map(payroll.lines, paid_row),
      ),
    ],
  )
}

fn paid_row(line: PayrollLine) -> Element(msg) {
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
fn view_variance(payroll: Payroll) -> Element(msg) {
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
        rows: list.map(payroll.lines, variance_row),
      ),
    ],
  )
}

/// The back-pay Δ for a line: the live recompute minus the frozen paid amount (a
/// not-yet-paid line owes its full preview).
fn line_delta(line: PayrollLine) -> Float {
  line.preview_amount -. option.unwrap(line.paid_amount, 0.0)
}

fn variance_row(line: PayrollLine) -> Element(msg) {
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
