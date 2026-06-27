//// The Finance Payroll tab (FR-F*), a self-contained sub-component MVU split out
//// of `client/page/finance`. The tab owns its own `Model` (its as-of, the loaded
//// payroll read model, and the open Run-payroll op form), its own `Msg`, its
//// `init`/`update`, and its `view`.
////
//// It reads `GET /api/payroll?from=&to=` for the month window of the rail date;
//// each result carries the `as_of` it answers so a stale reply is dropped. Its one
//// write is RunPayroll: pressing "Run payroll" opens the period op form; submitting
//// posts the command via `api.submit_operation` and, on success, raises
//// `OperationCommitted` and refetches the month.
////
//// `view` is adaptive across three states off the `run` / preview-vs-paid
//// reconciliation:
////   * no materialized run  -> a live PREVIEW of what would be paid, with the run
////     button;
////   * a run whose paid lines equal the live recompute -> RECONCILED, no button
////     (the DB refuses a re-run);
////   * a run a back-dated fact has since outgrown -> VARIANCE, the per-line Δ and
////     the total back-pay owed.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/set.{type Set}
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/command.{type Event}
import shared/money
import shared/payroll/view.{type Payroll, type PayrollLine, type PayrollSegment} as payroll_view

/// The Payroll tab's state: the as-of its data answers, the load state of the
/// payroll read model, the open Run-payroll op form (or `None`), and the set of
/// engineer ids whose per-level breakdown is currently disclosed.
pub type Model {
  Model(
    as_of: calendar.Date,
    payroll: Load,
    op: Option(ui.OpState),
    expanded: Set(Int),
  )
}

/// The payroll read model's load state.
pub type Load {
  Loading
  Loaded(payroll: Payroll)
  Failed(message: String)
}

/// The tab's messages: its own fetch result (carrying the `as_of` it answers), the
/// Run-payroll op lifecycle, and the operation reply.
pub type Msg {
  GotPayroll(as_of: calendar.Date, result: Result(Payroll, rsvp.Error(String)))
  OpOpened(permit: ui.Permit)
  OpFieldChanged(field: ui.OpField, value: String)
  OpSubmitted
  OpCancelled
  OpReplied(result: Result(List(Event), rsvp.Error(String)))
  ToggleExpanded(engineer_id: Int)
}

/// Start the tab at `as_of`, kicking off its payroll fetch.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(
    Model(as_of:, payroll: Loading, op: None, expanded: set.new()),
    fetch(as_of),
  )
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate), keeping any open
/// op form.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, payroll: Loading), fetch(as_of))
}

fn fetch(as_of: calendar.Date) -> Effect(Msg) {
  let from = time.iso_date(time.first_of_month(as_of))
  let to = time.iso_date(time.first_of_next_month(as_of))
  api.get(
    "/api/payroll?from=" <> from <> "&to=" <> to,
    payroll_view.payroll_decoder(),
    GotPayroll(as_of, _),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    GotPayroll(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let payroll = case result {
            Ok(payroll) -> Loaded(payroll:)
            Error(error) -> Failed(message: api.describe_error(error))
          }
          #(Model(..model, payroll:), effect.none(), [])
        }
      }

    OpOpened(..) -> {
      let form =
        ui.blank_op_form(kind: ui.OpRunPayroll, default_date: model.as_of)
      #(
        Model(
          ..model,
          op: Some(ui.OpState(kind: ui.OpRunPayroll, form:, error: None)),
        ),
        effect.none(),
        [],
      )
    }

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

    ToggleExpanded(engineer_id:) -> {
      let expanded = case set.contains(model.expanded, engineer_id) {
        True -> set.delete(model.expanded, engineer_id)
        False -> set.insert(model.expanded, engineer_id)
      }
      #(Model(..model, expanded:), effect.none(), [])
    }

    OpReplied(result:) ->
      case result {
        Ok(_) -> #(
          Model(..model, payroll: Loading, op: None),
          fetch(model.as_of),
          [OperationCommitted],
        )
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

// --- View -------------------------------------------------------------------

/// Render the tab: its loading guard and the op panel, delegating the loaded
/// render to `panel`. The run-payroll button raises `OpOpened`.
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let permit = ui.permit(permissions, own: False, kind: ui.OpRunPayroll)
  let body = case model.payroll {
    Loading -> ui.empty_state(message: "Loading payroll…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(payroll:) ->
      panel(
        payroll,
        on_run: OpOpened,
        permit: permit,
        expanded: model.expanded,
        on_toggle: ToggleExpanded,
      )
  }
  html.div([], [op_panel(model.op), body])
}

/// The open Run-payroll op as a centred modal, or nothing.
fn op_panel(op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(op) ->
      ui.modal(
        title: "Run payroll",
        error: option.unwrap(op.error, ""),
        body: op_fields(op.form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: "Run payroll",
      )
  }
}

fn op_fields(form: ui.OpForm) -> List(Element(Msg)) {
  [
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
}

/// Render the payroll for a loaded `payroll`, choosing the preview / reconciled /
/// variance presentation from the run state. `on_run` is dispatched when the
/// preview's "Run payroll" button is pressed.
pub fn panel(
  payroll: Payroll,
  on_run on_run: fn(ui.Permit) -> msg,
  permit permit: Result(ui.Permit, Nil),
  expanded expanded: Set(Int),
  on_toggle on_toggle: fn(Int) -> msg,
) -> Element(msg) {
  case payroll.run {
    None -> view_preview(payroll, on_run, permit, expanded, on_toggle)
    Some(_) ->
      case reconciled(payroll.lines) {
        True -> view_reconciled(payroll, expanded, on_toggle)
        False -> view_variance(payroll)
      }
  }
}

/// Whether every line's frozen paid amount still equals the live recompute exactly
/// — i.e. nothing has been back-dated since the run. Money is exact, so this is a
/// true equality, not a sub-cent tolerance. A line with no paid amount
/// (employed-but-not-in-run) counts as a variance.
pub fn reconciled(lines: List(PayrollLine)) -> Bool {
  list.all(lines, fn(line) {
    case line.paid_amount {
      Some(paid) -> money.compare(line.preview_amount, paid) == order.Eq
      None -> False
    }
  })
}

/// NOT YET RUN: the live recompute over current facts, the count of employed
/// engineers, the total to pay, and the run button.
fn view_preview(
  payroll: Payroll,
  on_run: fn(ui.Permit) -> msg,
  permit: Result(ui.Permit, Nil),
  expanded: Set(Int),
  on_toggle: fn(Int) -> msg,
) -> Element(msg) {
  let month = time.format_month(payroll.period_from)
  let count = list.length(payroll.lines)
  let total =
    money.sum(list.map(payroll.lines, fn(line) { line.preview_amount }))
  let run_button =
    ui.launch(
      permit,
      to_msg: on_run,
      label: "Run payroll",
      kind: ui.Primary,
      size: ui.Small,
    )
  ui.panel(
    title: "Payroll preview · " <> month,
    count: int.to_string(count) <> " employed · not yet run",
    right: [
      html.span([attribute.class("finance__total-note")], [
        html.text(ui.money(money.to_float(total)) <> " to pay"),
      ]),
      run_button,
    ],
    body: [
      ui.data_table(
        headers: [#("Engineer", False), #("Days", True), #("Preview", True)],
        rows: list.flat_map(payroll.lines, fn(line) {
          breakdown_rows(
            line,
            line.preview_segments,
            line.preview_days,
            line.preview_amount,
            expanded,
            on_toggle,
          )
        }),
      ),
    ],
  )
}

/// RUN, NO CHANGES: the frozen paid lines, reconciled against the live recompute.
/// No run button — the DB refuses a second run for the same month.
fn view_reconciled(
  payroll: Payroll,
  expanded: Set(Int),
  on_toggle: fn(Int) -> msg,
) -> Element(msg) {
  let month = time.format_month(payroll.period_from)
  let count = list.length(payroll.lines)
  let total =
    money.sum(
      list.map(payroll.lines, fn(line) {
        option.unwrap(line.paid_amount, money.zero())
      }),
    )
  ui.panel(
    title: "Payroll run · " <> month,
    count: int.to_string(count) <> " employed · reconciled",
    right: [
      html.span([attribute.class("finance__total-note")], [
        html.text(ui.money(money.to_float(total)) <> " paid"),
      ]),
    ],
    body: [
      ui.data_table(
        headers: [#("Engineer", False), #("Days", True), #("Paid", True)],
        rows: list.flat_map(payroll.lines, fn(line) {
          breakdown_rows(
            line,
            line.paid_segments,
            option.unwrap(line.paid_days, 0.0),
            option.unwrap(line.paid_amount, money.zero()),
            expanded,
            on_toggle,
          )
        }),
      ),
    ],
  )
}

/// One engineer's row(s) for a Days/amount table: the total row, plus — when the
/// breakdown has more than one salary level and the engineer is disclosed — an
/// indented sub-row per level (the pro-rated days and amount at that salary). A
/// single-level engineer is just the one total row, no toggle.
fn breakdown_rows(
  line: PayrollLine,
  segments: List(PayrollSegment),
  days: Float,
  amount: money.Money,
  expanded: Set(Int),
  on_toggle: fn(Int) -> msg,
) -> List(Element(msg)) {
  let total_row =
    html.tr([], [
      engineer_cell(line, segments, expanded, on_toggle),
      html.td([attribute.class("num")], [html.text(ui.days(days))]),
      html.td([attribute.class("num")], [
        html.text(ui.money(money.to_float(amount))),
      ]),
    ])
  case has_breakdown(segments) && set.contains(expanded, line.engineer_id) {
    True -> [total_row, ..list.map(segments, segment_row)]
    False -> [total_row]
  }
}

/// The engineer name cell — a disclosure toggle (▸/▾ + name) when the line has a
/// multi-level breakdown, otherwise the plain name.
fn engineer_cell(
  line: PayrollLine,
  segments: List(PayrollSegment),
  expanded: Set(Int),
  on_toggle: fn(Int) -> msg,
) -> Element(msg) {
  case has_breakdown(segments) {
    False -> html.td([], [html.text(line.engineer)])
    True -> {
      let marker = case set.contains(expanded, line.engineer_id) {
        True -> "▾ "
        False -> "▸ "
      }
      html.td([], [
        html.button(
          [
            attribute.class("payroll__disclosure"),
            event.on_click(on_toggle(line.engineer_id)),
          ],
          [html.text(marker <> line.engineer)],
        ),
      ])
    }
  }
}

/// An indented per-level sub-row: the seniority band and monthly salary, the
/// pro-rated days at that level, and the amount recognised.
fn segment_row(segment: PayrollSegment) -> Element(msg) {
  html.tr([attribute.class("payroll__segment")], [
    html.td([], [
      html.text(
        "↳ "
        <> ui.level_band(segment.level)
        <> " · "
        <> ui.money(money.to_float(segment.monthly_salary))
        <> "/mo",
      ),
    ]),
    html.td([attribute.class("num")], [html.text(ui.days(segment.days))]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(segment.amount))),
    ]),
  ])
}

/// Whether a line's breakdown has more than one salary level — the only case worth
/// disclosing (a mid-month promotion or salary revision).
fn has_breakdown(segments: List(PayrollSegment)) -> Bool {
  list.length(segments) > 1
}

/// RUN + VARIANCE: a fact was back-dated into the month after the run, so the live
/// recompute ("should be") no longer matches the frozen paid line for some
/// engineer. The header warns of the total back-pay owed; the table shows paid vs
/// should-be with the per-line Δ, the varying rows flagged.
fn view_variance(payroll: Payroll) -> Element(msg) {
  let month = time.format_month(payroll.period_from)
  let owed = money.sum(list.map(payroll.lines, line_delta))
  ui.panel(
    title: "Payroll run · " <> month,
    count: "",
    right: [
      html.span([attribute.class("finance__owed")], [
        html.text("⚠ " <> ui.money(money.to_float(owed)) <> " back-pay owed"),
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
fn line_delta(line: PayrollLine) -> money.Money {
  money.subtract(
    line.preview_amount,
    option.unwrap(line.paid_amount, money.zero()),
  )
}

fn variance_row(line: PayrollLine) -> Element(msg) {
  let delta = line_delta(line)
  let varies = money.compare(delta, money.zero()) != order.Eq
  let row_class = case varies {
    True -> "finance__variance-row"
    False -> ""
  }
  let delta_text = case varies {
    True -> ui.money(money.to_float(delta))
    False -> "—"
  }
  let delta_class = case varies {
    True -> "num finance__owed"
    False -> "num"
  }
  html.tr([attribute.class(row_class)], [
    html.td([], [html.text(line.engineer)]),
    html.td([attribute.class("num")], [
      html.text(
        ui.money(money.to_float(option.unwrap(line.paid_amount, money.zero()))),
      ),
    ]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(line.preview_amount))),
    ]),
    html.td([attribute.class(delta_class)], [html.text(delta_text)]),
  ])
}
