//// The Finance Payroll tab (FR-F*), a self-contained sub-component MVU split out
//// of `client/page/finance`. The tab owns its own `Model` (its as-of, the loaded
//// payroll summary read model, the selected mode, the payroll table host, and the
//// open Run-payroll op form), its own `Msg`, its `init`/`update`, and its `view`.
////
//// The engineer rows render via the generic data table, embedded through
//// `table_host` with the month window (`from`/`to`) as fixed base params, reading
//// `GET /api/payroll/table?from=&to=&mode=`. Each engineer total expands to its
//// per-salary-level segment sub-rows (the nesting now comes from `Row.children` and
//// the table's own expand UI). The summary `GET /api/payroll?from=&to=` is still
//// fetched alongside, for the run state (which mode to default to), the headline
//// totals, and the Run-payroll launcher.
////
//// The tab has three modes the user switches between:
////   * PREVIEW    — the live recompute of what would be paid, with the run button;
////   * RECONCILED — a run whose paid lines equal the live recompute, no button;
////   * VARIANCE   — a run a back-dated fact has since outgrown, the per-line Δ.
//// The run state picks the default mode; the user can switch via the mode tabs.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/table_host
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
import shared/money
import shared/payroll/view.{type Payroll, type PayrollLine} as payroll_view

/// The payroll table modes the user switches between.
pub type Mode {
  Preview
  Reconciled
  Variance
}

fn mode_param(mode: Mode) -> String {
  case mode {
    Preview -> "preview"
    Reconciled -> "reconciled"
    Variance -> "variance"
  }
}

fn mode_label(mode: Mode) -> String {
  case mode {
    Preview -> "Preview"
    Reconciled -> "Reconciled"
    Variance -> "Variance"
  }
}

/// The Payroll tab's state: the as-of its data answers, the load state of the
/// payroll summary read model, the selected mode, the table host, and the open
/// Run-payroll op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    payroll: Load,
    mode: Mode,
    host: table_host.Host,
    op: Option(ui.OpState),
  )
}

/// The payroll summary read model's load state.
pub type Load {
  Loading
  Loaded(payroll: Payroll)
  Failed(message: String)
}

/// The tab's messages: the summary fetch result (carrying the `as_of` it answers),
/// the table host's sub-messages, the mode switch, the Run-payroll op lifecycle, and
/// the operation reply.
pub type Msg {
  GotPayroll(as_of: calendar.Date, result: Result(Payroll, rsvp.Error(String)))
  TableHostMsg(sub: table_host.Msg)
  ModePicked(mode: Mode)
  OpOpened(permit: ui.Permit)
  OpFieldChanged(field: ui.OpField, value: String)
  OpSubmitted
  OpCancelled
  OpReplied(result: Result(Nil, rsvp.Error(String)))
}

/// Start the tab at `as_of`, kicking off its summary fetch and the table host (in
/// the default Preview mode).
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let mode = Preview
  let #(host, host_effect) =
    table_host.init_with("/api/payroll/table", base(as_of, mode), as_of)
  #(
    Model(as_of:, payroll: Loading, mode:, host:, op: None),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
}

/// Re-fetch the tab for a new `as_of` (stale-while-revalidate), keeping the selected
/// mode and any open op form. The table host re-fetches against the new window.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let #(host, host_effect) =
    table_host.refetch_with(model.host, base(as_of, model.mode), as_of)
  #(
    Model(..model, as_of:, payroll: Loading, host:),
    effect.batch([fetch(as_of), effect.map(host_effect, TableHostMsg)]),
  )
}

/// The fixed base query params for the table host: the month window of `as_of` and
/// the selected mode.
fn base(as_of: calendar.Date, mode: Mode) -> List(#(String, String)) {
  [
    #("from", time.iso_date(time.first_of_month(as_of))),
    #("to", time.iso_date(time.first_of_next_month(as_of))),
    #("mode", mode_param(mode)),
  ]
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
        True ->
          case result {
            Ok(payroll) -> on_summary(model, payroll)
            Error(error) -> #(
              Model(..model, payroll: Failed(api.describe_error(error))),
              effect.none(),
              [],
            )
          }
      }

    TableHostMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.host, sub, model.as_of)
      let model = Model(..model, host:)
      let effect = effect.map(host_effect, TableHostMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(id: _) -> #(model, effect, [])
        table_host.ActionInvoked(..) -> #(model, effect, [])
      }
    }

    ModePicked(mode:) ->
      case mode == model.mode {
        True -> #(model, effect.none(), [])
        False -> {
          let #(host, host_effect) =
            table_host.refetch_with(
              model.host,
              base(model.as_of, mode),
              model.as_of,
            )
          #(
            Model(..model, mode:, host:),
            effect.map(host_effect, TableHostMsg),
            [],
          )
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

    OpReplied(result:) ->
      case result {
        Ok(_) -> {
          let #(host, host_effect) =
            table_host.refetch_with(
              model.host,
              base(model.as_of, model.mode),
              model.as_of,
            )
          #(
            Model(..model, payroll: Loading, host:, op: None),
            effect.batch([
              fetch(model.as_of),
              effect.map(host_effect, TableHostMsg),
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

/// Adopt a fresh summary read: default the selected mode to the one the run state
/// implies (preview before a run, reconciled when the run still matches the live
/// recompute, variance once a back-dated fact has outgrown it), and re-point the
/// table host at that mode.
fn on_summary(
  model: Model,
  payroll: Payroll,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  let mode = default_mode(payroll)
  let #(host, host_effect) =
    table_host.refetch_with(model.host, base(model.as_of, mode), model.as_of)
  #(
    Model(..model, payroll: Loaded(payroll:), mode:, host:),
    effect.map(host_effect, TableHostMsg),
    [],
  )
}

/// The mode the run state implies: preview before a run exists, reconciled while
/// every paid line still equals the live recompute, variance once a back-dated fact
/// has moved a line.
fn default_mode(payroll: Payroll) -> Mode {
  case payroll.run {
    None -> Preview
    Some(_) ->
      case reconciled(payroll.lines) {
        True -> Reconciled
        False -> Variance
      }
  }
}

/// Whether every line's frozen paid amount still equals the live recompute exactly
/// — i.e. nothing has been back-dated since the run. A line with no paid amount
/// counts as a variance.
fn reconciled(lines: List(PayrollLine)) -> Bool {
  list.all(lines, fn(line) {
    case line.paid_amount {
      Some(paid) -> money.compare(line.preview_amount, paid) == order.Eq
      None -> False
    }
  })
}

// --- View -------------------------------------------------------------------

/// Render the tab: its loading guard and the op panel, delegating the loaded render
/// to `panel`. The run-payroll button raises `OpOpened`.
pub fn view(model: Model, permissions: Set(String)) -> Element(Msg) {
  let permit = ui.permit(permissions, own: False, kind: ui.OpRunPayroll)
  let body = case model.payroll {
    Loading -> ui.empty_state(message: "Loading payroll…")
    Failed(message:) -> ui.empty_state(message: message)
    Loaded(payroll:) -> panel(model, payroll, permit)
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

/// Render the payroll panel: the headline (period, run state, the to-pay/paid/owed
/// total, the Run-payroll button when previewing), the mode tabs, and the engineer
/// table for the selected mode (each row expandable to its per-level segments).
fn panel(
  model: Model,
  payroll: Payroll,
  permit: Result(ui.Permit, Nil),
) -> Element(Msg) {
  let month = time.format_month(payroll.period_from)
  let count = int.to_string(list.length(payroll.lines)) <> " employed"
  ui.panel(
    title: "Payroll · " <> month,
    count:,
    right: headline(model.mode, payroll, permit),
    body: [
      mode_tabs(model.mode),
      element.map(table_host.view(model.host, "Loading payroll…"), TableHostMsg),
    ],
  )
}

/// The right-hand headline cluster for the selected mode: the total to pay (preview),
/// the total paid (reconciled), or the back-pay owed (variance); the preview also
/// shows the Run-payroll launcher.
fn headline(
  mode: Mode,
  payroll: Payroll,
  permit: Result(ui.Permit, Nil),
) -> List(Element(Msg)) {
  case mode {
    Preview -> {
      let total =
        money.sum(list.map(payroll.lines, fn(line) { line.preview_amount }))
      [
        html.span([attribute.class("finance__total-note")], [
          html.text(ui.money(money.to_float(total)) <> " to pay"),
        ]),
        ui.launch(
          permit,
          to_msg: OpOpened,
          label: "Run payroll",
          kind: ui.Primary,
          size: ui.Small,
        ),
      ]
    }
    Reconciled -> {
      let total =
        money.sum(
          list.map(payroll.lines, fn(line) {
            option.unwrap(line.paid_amount, money.zero())
          }),
        )
      [
        html.span([attribute.class("finance__total-note")], [
          html.text(ui.money(money.to_float(total)) <> " paid"),
        ]),
      ]
    }
    Variance -> {
      let owed =
        money.sum(
          list.map(payroll.lines, fn(line) {
            money.subtract(
              line.preview_amount,
              option.unwrap(line.paid_amount, money.zero()),
            )
          }),
        )
      case money.to_float(owed) >. 0.0 {
        True -> [
          html.span([attribute.class("finance__owed")], [
            html.text("⚠ " <> ui.money(money.to_float(owed)) <> " back-pay owed"),
          ]),
        ]
        False -> [
          html.span([attribute.class("finance__reconciled")], [
            html.text("✓ Fully reconciled"),
          ]),
        ]
      }
    }
  }
}

/// The mode switcher: a tab per mode, the selected one marked active.
fn mode_tabs(selected: Mode) -> Element(Msg) {
  html.div(
    [attribute.class("payroll__modes")],
    list.map([Preview, Reconciled, Variance], fn(mode) {
      let active = case mode == selected {
        True -> " payroll__mode--active"
        False -> ""
      }
      html.button(
        [
          attribute.class("payroll__mode" <> active),
          event.on_click(ModePicked(mode)),
        ],
        [html.text(mode_label(mode))],
      )
    }),
  )
}
