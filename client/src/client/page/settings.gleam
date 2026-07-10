//// The Settings page (FR-ST*): the rate card, salary bands, and leave policy as
//// of the global rail date. Writes: ReviseRateCard, AdjustRateForPortion,
//// SetSalary.
////
//// The rate-card & salary-bands table and the read-only leave-policy table both
//// render via the generic data table, embedded through `table_host` (`GET
//// /api/settings/rate-card/table?as_of=` and `GET /api/settings/leave-policy/
//// table?as_of=`). The rate-card table carries a server-advertised actions column;
//// its `Out.ActionInvoked(action, level)` opens the matching op form pre-filled
//// with that level's current rate/salary. The op-form directory (level options and
//// pre-fill amounts) still comes from `GET /api/settings?as_of=`.
////
//// Revisions are temporal: they apply from an effective date forward, so each
//// op-form defaults its date fields to the rail's current day. The three writes
//// reuse the shared `ui` op-form engine and open in the shared `atoms.modal`; on a
//// committed write the page raises `OperationCommitted` and refetches so the tables
//// reflect the new version.

import client/api
import client/page.{type OutMsg, OperationCommitted}
import client/route
import client/table_host
import client/time
import client/ui/atoms
import client/ui/format
import client/ui/op_commands
import client/ui/ops
import gleam/float
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
import shared/money
import shared/settings/view.{type Settings} as settings_view

// --- Model ------------------------------------------------------------------

/// The page's state. The two table hosts (rate card & salary; leave policy) own
/// their own load state and live across every variant. The op-form directory (the
/// `Settings` read that feeds the level `<select>` and pre-fill amounts) is tracked
/// separately as `Directory`. Every variant carries the signed-in `actor` so a
/// submitted write is stamped with the right actor, and the rail `as_of`.
pub type Model {
  Model(
    actor: String,
    as_of: calendar.Date,
    rate_card: table_host.Host,
    leave_policy: table_host.Host,
    directory: Directory,
    op: Option(ops.OpState),
  )
}

/// The op-form directory's load state: the `Settings` read whose rate card supplies
/// the level options and the per-level pre-fill amounts.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(settings: Settings)
  DirectoryFailed(message: String)
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `SettingsMsg(settings.Msg)`.
pub type Msg {
  RateCardMsg(sub: table_host.Msg)
  LeavePolicyMsg(sub: table_host.Msg)
  DirectoryFetched(
    as_of: calendar.Date,
    result: Result(Settings, rsvp.Error(String)),
  )
  OpStarted(permit: ops.Permit)
  OpDismissed
  OpFieldEdited(field: ops.OpField, value: String)
  OpSubmitted
  OpResponded(result: Result(Nil, rsvp.Error(String)))
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `as_of` on the signed-in `actor`'s behalf,
/// kicking off the two table fetches and the op-form directory. Settings has no
/// detail sub-view, so the `route` payload is ignored.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = route
  let #(rate_card, rate_effect) =
    table_host.init("/api/settings/rate-card/table", as_of)
  let #(leave_policy, leave_effect) =
    table_host.init("/api/settings/leave-policy/table", as_of)
  let model =
    Model(
      actor:,
      as_of:,
      rate_card:,
      leave_policy:,
      directory: DirectoryLoading,
      op: None,
    )
  #(
    model,
    effect.batch([
      effect.map(rate_effect, RateCardMsg),
      effect.map(leave_effect, LeavePolicyMsg),
      fetch_directory(as_of),
    ]),
  )
}

/// Re-fetch settings for a new `as_of` (stale-while-revalidate), keeping any open
/// op form and the tables' active layout. The signed-in `actor` is refreshed.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let #(rate_card, rate_effect) = table_host.refetch(model.rate_card, as_of)
  let #(leave_policy, leave_effect) =
    table_host.refetch(model.leave_policy, as_of)
  #(
    Model(
      ..model,
      actor:,
      as_of:,
      rate_card:,
      leave_policy:,
      directory: DirectoryLoading,
    ),
    effect.batch([
      effect.map(rate_effect, RateCardMsg),
      effect.map(leave_effect, LeavePolicyMsg),
      fetch_directory(as_of),
    ]),
  )
}

/// The op-form directory fetch for a date, tagging the result with the `as_of` it
/// answers so a late reply for an earlier date can be dropped.
fn fetch_directory(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/settings?as_of=" <> time.iso_date(as_of),
    settings_view.settings_decoder(),
    fn(result) { DirectoryFetched(as_of:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    RateCardMsg(sub:) -> {
      let #(host, host_effect, out) =
        table_host.update(model.rate_card, sub, model.as_of)
      let model = Model(..model, rate_card: host)
      let effect = effect.map(host_effect, RateCardMsg)
      case out {
        table_host.Stay -> #(model, effect, [])
        table_host.Activated(..) -> #(model, effect, [])
        table_host.ActionInvoked(action:, row:) -> {
          let #(next, op_effect) = open_action(model, action, row)
          #(next, effect.batch([effect, op_effect]), [])
        }
      }
    }

    LeavePolicyMsg(sub:) -> {
      let #(host, host_effect, _out) =
        table_host.update(model.leave_policy, sub, model.as_of)
      #(
        Model(..model, leave_policy: host),
        effect.map(host_effect, LeavePolicyMsg),
        [],
      )
    }

    DirectoryFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let directory = case result {
            Ok(settings) -> DirectoryLoaded(settings:)
            Error(error) -> DirectoryFailed(message: api.describe_error(error))
          }
          #(Model(..model, directory:), effect.none(), [])
        }
      }

    OpStarted(permit:) -> {
      let kind = ops.permit_kind(permit)
      let form = ops.blank_op_form(kind:, default_date: model.as_of)
      #(
        Model(..model, op: Some(ops.OpState(kind:, form:, error: None))),
        effect.none(),
        [],
      )
    }

    OpDismissed -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(state) -> {
          let form = ops.update_op_form(state.form, field, value)
          #(
            Model(..model, op: Some(ops.OpState(..state, form:, error: None))),
            effect.none(),
            [],
          )
        }
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(state) ->
          case op_commands.build_command(state.kind, state.form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ops.OpState(..state, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case model.op {
        Some(state) ->
          case result {
            Ok(_) -> {
              let #(refreshed, refetch_effect) =
                refetch(Model(..model, op: None), model.as_of, model.actor)
              #(refreshed, refetch_effect, [OperationCommitted])
            }
            Error(error) -> #(
              Model(
                ..model,
                op: Some(
                  ops.OpState(..state, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }
  }
}

/// Open the op form a rate-card action invokes for a level: `revise_rate` opens the
/// Revise-rate form pre-filled with the level's current day rate; `set_salary`
/// opens the Set-salary form pre-filled with its monthly salary. An unknown action,
/// an unparseable level, or a not-yet-loaded directory is a no-op.
fn open_action(
  model: Model,
  action: String,
  row: String,
) -> #(Model, Effect(Msg)) {
  case model.directory, int.parse(row) {
    DirectoryLoaded(settings:), Ok(level) -> {
      let #(kind, amount) = case action {
        "revise_rate" -> #(
          ops.OpReviseRateCard,
          day_rate_amount(settings, level),
        )
        "set_salary" -> #(ops.OpSetSalary, salary_amount(settings, level))
        _ -> #(ops.OpReviseRateCard, 0.0)
      }
      let form =
        ops.blank_op_form(kind:, default_date: model.as_of)
        |> ops.update_op_form(ops.FLevel, int.to_string(level))
        |> ops.update_op_form(amount_field(kind), number_value(amount))
      #(
        Model(..model, op: Some(ops.OpState(kind:, form:, error: None))),
        effect.none(),
      )
    }
    _, _ -> #(model, effect.none())
  }
}

/// The form slot the per-row amount pre-fills for a kind: the day rate for a
/// rate-card revision, the monthly salary for a salary set. Other kinds carry no
/// per-row amount, so the slot is irrelevant and defaults to the day rate.
fn amount_field(kind: ops.OpKind) -> ops.OpField {
  case kind {
    ops.OpSetSalary -> ops.FMonthlySalary
    _ -> ops.FDayRate
  }
}

/// A money amount as a plain number string suitable for a number input (no "$" or
/// thousands separators), so a pre-filled rate/salary round-trips through
/// `build_command`. Whole amounts render without a trailing ".0".
fn number_value(amount: Float) -> String {
  case amount == int.to_float(float.round(amount)) {
    True -> int.to_string(float.round(amount))
    False -> float.to_string(amount)
  }
}

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`.
pub fn view(
  model: Model,
  as_of: calendar.Date,
  permissions: Set(String),
) -> Element(Msg) {
  let _ = as_of
  let actions = [
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpAdjustRateForPortion),
      to_msg: OpStarted,
      label: "Adjust window",
      kind: atoms.Ghost,
      size: atoms.Small,
    ),
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpSetSalary),
      to_msg: OpStarted,
      label: "Set salary",
      kind: atoms.Ghost,
      size: atoms.Small,
    ),
    ops.launch(
      ops.permit(permissions, own: False, kind: ops.OpReviseRateCard),
      to_msg: OpStarted,
      label: "Revise rate",
      kind: atoms.Primary,
      size: atoms.Small,
    ),
  ]
  html.div([], [
    head(actions),
    html.div([attribute.class("settings-grid")], [
      atoms.panel(
        title: "Rate card & salary bands",
        count: "",
        right: [],
        body: [
          element.map(
            table_host.view(model.rate_card, "Loading rate card…"),
            RateCardMsg,
          ),
        ],
      ),
      atoms.panel(title: "Leave policy", count: "read-only", right: [], body: [
        element.map(
          table_host.view(model.leave_policy, "Loading leave policy…"),
          LeavePolicyMsg,
        ),
      ]),
    ]),
    view_op(model),
  ])
}

/// The page head, with an optional cluster of head actions on the right.
fn head(actions: List(Element(Msg))) -> Element(Msg) {
  atoms.page_head(
    title: "Settings",
    blurb: "Rate card, salary bands, and leave policy. Changes here are temporal — they apply from an effective date forward.",
    actions: actions,
  )
}

// --- Op form modal -----------------------------------------------------------

/// The open contextual operation, shown as a centred modal over a dimmed backdrop
/// when an op is open. Renders the fields the op needs (level as a `<select>` over
/// the levels present in the rate card, the rate/salary, and the temporal dates),
/// the last rejection sentence, and the Cancel / Confirm footer.
fn view_op(model: Model) -> Element(Msg) {
  case model.op {
    None -> element.none()
    Some(state) ->
      atoms.modal(
        title: op_title(state.kind),
        error: option.unwrap(state.error, ""),
        body: op_fields(model, state),
        on_cancel: OpDismissed,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(state.kind),
      )
  }
}

/// The human title for an op kind.
fn op_title(kind: ops.OpKind) -> String {
  case kind {
    ops.OpReviseRateCard -> "Revise rate card"
    ops.OpAdjustRateForPortion -> "Adjust rate for a window"
    ops.OpSetSalary -> "Set salary"
    _ -> "Operation"
  }
}

/// The confirm-button verb for an op kind.
fn op_verb(kind: ops.OpKind) -> String {
  case kind {
    ops.OpReviseRateCard -> "Revise"
    ops.OpAdjustRateForPortion -> "Adjust"
    ops.OpSetSalary -> "Set salary"
    _ -> "Confirm"
  }
}

/// The input fields for the open op kind, each bound to its `OpForm` slot. The
/// level is a `<select>` over the levels present in the rate card; the amount and
/// dates are text/number/date inputs. Only the settings writes are reachable here.
fn op_fields(model: Model, state: ops.OpState) -> List(Element(Msg)) {
  let field = fn(label, slot, input_type, value) {
    ops.op_field(
      label: label,
      field: slot,
      value: value,
      input_type: input_type,
      to_msg: OpFieldEdited,
    )
  }
  let form = state.form
  case state.kind {
    ops.OpReviseRateCard -> [
      level_select(model, form.level),
      field("Day rate", ops.FDayRate, "number", form.day_rate),
      field("Effective", ops.FEffective, "date", form.effective),
    ]
    ops.OpAdjustRateForPortion -> [
      level_select(model, form.level),
      field("Day rate", ops.FDayRate, "number", form.day_rate),
      field("Valid from", ops.FValidFrom, "date", form.valid_from),
      field("Valid to", ops.FValidTo, "date", form.valid_to),
    ]
    ops.OpSetSalary -> [
      level_select(model, form.level),
      field("Monthly salary", ops.FMonthlySalary, "number", form.monthly_salary),
      field("Effective", ops.FEffective, "date", form.effective),
    ]
    _ -> []
  }
}

/// A labelled `<select>` over the levels present in the loaded directory's rate
/// card, bound to the `FLevel` slot. Empty until the directory loads.
fn level_select(model: Model, selected: String) -> Element(Msg) {
  let rate_card = case model.directory {
    DirectoryLoaded(settings:) -> settings.rate_card
    _ -> []
  }
  let options =
    list.map(rate_card, fn(rate) {
      let level = int.to_string(rate.level)
      html.option(
        [attribute.value(level), attribute.selected(level == selected)],
        format.level_band(rate.level),
      )
    })
  html.label([attribute.class("op-form__field")], [
    html.span([], [html.text("Level")]),
    html.select(
      [
        attribute.attribute("aria-label", "Level"),
        event.on_change(fn(value) { OpFieldEdited(ops.FLevel, value) }),
      ],
      options,
    ),
  ])
}

/// The raw day rate for a level from the loaded directory, or 0.0 when absent.
fn day_rate_amount(settings: Settings, level: Int) -> Float {
  case list.find(settings.rate_card, fn(rate) { rate.level == level }) {
    Ok(rate) -> money.to_float(rate.day_rate)
    Error(Nil) -> 0.0
  }
}

/// The raw monthly salary for a level from the loaded directory, or 0.0 when no
/// band covers it.
fn salary_amount(settings: Settings, level: Int) -> Float {
  case list.find(settings.salaries, fn(salary) { salary.level == level }) {
    Ok(salary) -> money.to_float(salary.monthly_salary)
    Error(Nil) -> 0.0
  }
}
