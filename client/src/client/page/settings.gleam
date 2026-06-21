//// The Settings page (FR-ST*): the rate card, salary bands, and leave policy as
//// of the global rail date. Writes: ReviseRateCard, AdjustRateForPortion,
//// SetSalary.
////
//// Reads `GET /api/settings?as_of=` into a per-level rate-card & salary-bands
//// table (level rendered via `ui.level_band`) and a READ-ONLY leave-policy table.
//// Leave policy carries no control (SetLeavePolicy is deferred per ADR-034) — it
//// is presented as facts only, never a dead button.
////
//// Revisions are temporal: they apply from an effective date forward, so each
//// op-form defaults its date fields to the rail's current day. The three writes
//// reuse the shared `ui` op-form engine; on a committed write the page raises
//// `OperationCommitted` and refetches so the tables reflect the new version.

import client/api
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
import rsvp
import shared/codecs
import shared/types.{type Settings}

// --- Model ------------------------------------------------------------------

/// The page's state. Every variant carries the signed-in `actor` (threaded from
/// `init`/`refetch`, since `update` is not given it) so a submitted write can be
/// stamped with the right actor. `Loaded` additionally carries the settings it
/// answers (tagged with the `as_of` so a stale fetch can be dropped) and the
/// currently-open op form (if any). `Failed` carries the fetch error sentence.
pub type Model {
  Loading(actor: String)
  Loaded(
    actor: String,
    as_of: calendar.Date,
    settings: Settings,
    op: Option(OpState),
  )
  Failed(actor: String, message: String)
}

/// The open contextual operation: which kind it is, the form being typed, and any
/// rejection sentence from the last submit attempt.
pub type OpState {
  OpState(kind: ui.OpKind, form: ui.OpForm, error: Option(String))
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `SettingsMsg(settings.Msg)`.
pub type Msg {
  SettingsFetched(
    as_of: calendar.Date,
    result: Result(Settings, rsvp.Error(String)),
  )
  OpStarted(kind: ui.OpKind)
  OpDismissed
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OpResponded(result: Result(List(types.Event), rsvp.Error(String)))
}

/// The cross-page effects a page can raise (the ONLY shell coupling, frozen in
/// step 5): navigate to a route, or signal a write committed.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `as_of` on the signed-in `actor`'s behalf,
/// kicking off the settings fetch. Settings has no detail sub-view, so the
/// `route` payload is ignored.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = route
  #(Loading(actor:), fetch(as_of))
}

/// Re-fetch settings for a new `as_of` without dropping a half-typed op form: the
/// open `OpState` is preserved across the refetch (stale-while-revalidate); the
/// in-flight result is reconciled against the model's as_of in `update`. The
/// signed-in `actor` is refreshed onto the model in case it changed.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(with_actor(model, actor), fetch(as_of))
}

/// The settings fetch for a date, tagging the result with the `as_of` it answers
/// so a late reply for an earlier date can be dropped.
fn fetch(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/settings?as_of=" <> time.iso_date(as_of),
    codecs.settings_decoder(),
    fn(result) { SettingsFetched(as_of:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  let actor = actor_of(model)
  case msg {
    SettingsFetched(as_of:, result:) ->
      case result {
        Ok(settings) ->
          case settings.date == as_of {
            True -> #(
              Loaded(actor:, as_of:, settings:, op: keep_op(model)),
              effect.none(),
              [],
            )
            False -> #(model, effect.none(), [])
          }
        Error(error) -> #(
          Failed(actor:, message: api.describe_error(error)),
          effect.none(),
          [],
        )
      }

    OpStarted(kind:) ->
      case model {
        Loaded(as_of:, settings:, ..) -> {
          let form = ui.blank_op_form(kind:, default_date: as_of)
          #(
            Loaded(
              actor:,
              as_of:,
              settings:,
              op: Some(OpState(kind:, form:, error: None)),
            ),
            effect.none(),
            [],
          )
        }
        _ -> #(model, effect.none(), [])
      }

    OpDismissed ->
      case model {
        Loaded(as_of:, settings:, ..) -> #(
          Loaded(actor:, as_of:, settings:, op: None),
          effect.none(),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    OpFieldEdited(field:, value:) ->
      case model {
        Loaded(as_of:, settings:, op: Some(state), ..) -> {
          let form = ui.update_op_form(state.form, field, value)
          #(
            Loaded(
              actor:,
              as_of:,
              settings:,
              op: Some(OpState(..state, form:, error: None)),
            ),
            effect.none(),
            [],
          )
        }
        _ -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model {
        Loaded(as_of:, settings:, op: Some(state), ..) ->
          case ui.build_command(state.kind, state.form) {
            Ok(command) -> #(
              model,
              api.submit_operation(actor, command, OpResponded),
              [],
            )
            Error(prompt) -> #(
              Loaded(
                actor:,
                as_of:,
                settings:,
                op: Some(OpState(..state, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        _ -> #(model, effect.none(), [])
      }

    OpResponded(result:) ->
      case model {
        Loaded(as_of:, settings:, op: Some(state), ..) ->
          case result {
            Ok(_) -> #(
              Loaded(actor:, as_of:, settings:, op: None),
              fetch(as_of),
              [OperationCommitted],
            )
            Error(error) -> #(
              Loaded(
                actor:,
                as_of:,
                settings:,
                op: Some(
                  OpState(..state, error: Some(api.describe_error(error))),
                ),
              ),
              effect.none(),
              [],
            )
          }
        _ -> #(model, effect.none(), [])
      }
  }
}

/// The op form to keep across a refetch or a fresh read: the open form survives so
/// a half-typed revision is never clobbered; a closed form stays closed.
fn keep_op(model: Model) -> Option(OpState) {
  case model {
    Loaded(op:, ..) -> op
    _ -> None
  }
}

/// The signed-in actor carried by any model variant.
fn actor_of(model: Model) -> String {
  case model {
    Loading(actor:) -> actor
    Loaded(actor:, ..) -> actor
    Failed(actor:, ..) -> actor
  }
}

/// Replace the actor on whichever model variant is current (used by `refetch`).
fn with_actor(model: Model, actor: String) -> Model {
  case model {
    Loading(..) -> Loading(actor:)
    Loaded(as_of:, settings:, op:, ..) -> Loaded(actor:, as_of:, settings:, op:)
    Failed(message:, ..) -> Failed(actor:, message:)
  }
}

// --- View -------------------------------------------------------------------

/// Render the page for `as_of`.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  case model {
    Loading(..) -> view_shell([ui.empty_state(message: "Loading settings…")])
    Failed(message:, ..) -> view_shell([ui.empty_state(message: message)])
    Loaded(settings:, op:, ..) -> view_loaded(settings, op)
  }
}

/// Wrap a body in the standard settings page head.
fn view_shell(body: List(Element(Msg))) -> Element(Msg) {
  html.div([], [head([]), ..body])
}

/// The page head, with an optional cluster of head actions on the right.
fn head(actions: List(Element(Msg))) -> Element(Msg) {
  ui.page_head(
    title: "Settings",
    blurb: "Rate card, salary bands, and leave policy. Changes here are temporal — they apply from an effective date forward.",
    actions: actions,
  )
}

/// The loaded view: the page head with the New rate / New salary actions, the
/// optional open op-form, then the `.settings-grid` two-column layout of the rate-card &
/// salary table and the read-only leave-policy table.
fn view_loaded(settings: Settings, op: Option(OpState)) -> Element(Msg) {
  let actions = [
    html.button(
      [
        attribute.class("btn btn--ghost btn--sm"),
        event.on_click(OpStarted(ui.OpAdjustRateForPortion)),
      ],
      [html.text("Adjust window")],
    ),
    html.button(
      [
        attribute.class("btn btn--ghost btn--sm"),
        event.on_click(OpStarted(ui.OpSetSalary)),
      ],
      [html.text("Set salary")],
    ),
    html.button(
      [
        attribute.class("btn btn--sm"),
        event.on_click(OpStarted(ui.OpReviseRateCard)),
      ],
      [html.text("Revise rate")],
    ),
  ]
  html.div([], [
    head(actions),
    view_op(op),
    html.div([attribute.class("settings-grid")], [
      view_rate_card(settings),
      view_leave_policy(settings),
    ]),
  ])
}

/// The rate-card & salary-bands panel: one row per level present in the rate card,
/// showing the level band, day rate, monthly salary (from the salaries list, "—"
/// when absent), and a per-row Revise button.
fn view_rate_card(settings: Settings) -> Element(Msg) {
  let rows =
    list.map(settings.rate_card, fn(rate) {
      let salary = salary_for(settings.salaries, rate.level)
      html.tr([], [
        html.td([], [
          html.span([attribute.class("level-pill")], [
            html.text(ui.level_band(rate.level)),
          ]),
        ]),
        html.td([attribute.class("num")], [html.text(ui.money(rate.day_rate))]),
        html.td([attribute.class("num")], [html.text(salary)]),
        html.td([attribute.class("num")], [
          html.button(
            [
              attribute.class("btn btn--ghost btn--sm"),
              event.on_click(OpStarted(ui.OpReviseRateCard)),
            ],
            [html.text("Revise")],
          ),
        ]),
      ])
    })
  ui.panel(title: "Rate card & salary bands", count: "", right: [], body: [
    ui.data_table(
      headers: [
        #("Level", False),
        #("Day rate", True),
        #("Monthly salary", True),
        #("", False),
      ],
      rows: rows,
    ),
  ])
}

/// The monthly salary for a level, formatted as money, or "—" when no salary band
/// covers the level as-of the date.
fn salary_for(salaries: List(types.SalaryRow), level: Int) -> String {
  case list.find(salaries, fn(salary) { salary.level == level }) {
    Ok(salary) -> ui.money(salary.monthly_salary)
    Error(Nil) -> "—"
  }
}

/// The READ-ONLY leave-policy panel: one row per policy row showing the leave kind,
/// the level band it applies to, and the days-per-year entitlement. A (kind, level)
/// absent from the list is unlimited; it simply does not appear. No control —
/// SetLeavePolicy is deferred (ADR-034).
fn view_leave_policy(settings: Settings) -> Element(Msg) {
  let body = case settings.leave_policy {
    [] -> [ui.empty_state(message: "No leave policy set on this date.")]
    policies -> [
      ui.data_table(
        headers: [
          #("Type", False),
          #("Level", False),
          #("Days / year", True),
        ],
        rows: list.map(policies, fn(policy) {
          html.tr([], [
            html.td([], [html.text(policy.kind)]),
            html.td([], [
              html.span([attribute.class("level-pill")], [
                html.text(ui.level_band(policy.level)),
              ]),
            ]),
            html.td([attribute.class("num")], [
              html.text(ui.days(policy.days_per_year)),
            ]),
          ])
        }),
      ),
    ]
  }
  ui.panel(title: "Leave policy", count: "read-only", right: [], body: body)
}

/// The open op-form panel, or nothing when no op is open. Renders only the fields
/// the open kind needs, a rejection sentence if the last attempt failed, and
/// Apply/Cancel controls.
fn view_op(op: Option(OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(state) ->
      ui.panel(
        title: op_title(state.kind),
        count: "",
        right: [
          html.button(
            [
              attribute.class("btn btn--ghost btn--sm"),
              event.on_click(OpDismissed),
            ],
            [html.text("Cancel")],
          ),
        ],
        body: [
          html.div([attribute.class("op-form")], [
            html.div([attribute.class("op-form__fields")], op_fields(state)),
            op_error(state.error),
            html.div([attribute.class("action-row")], [
              html.button(
                [attribute.class("btn btn--sm"), event.on_click(OpSubmitted)],
                [html.text("Apply")],
              ),
            ]),
          ]),
        ],
      )
  }
}

/// The human title for an op kind.
fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpReviseRateCard -> "Revise rate card"
    ui.OpAdjustRateForPortion -> "Adjust rate for a window"
    ui.OpSetSalary -> "Set salary"
    _ -> "Operation"
  }
}

/// The input fields for the open op kind, each bound to its `OpForm` slot via
/// `ui.op_field`. Only the settings writes are reachable here.
fn op_fields(state: OpState) -> List(Element(Msg)) {
  let field = fn(label, slot, input_type, value) {
    ui.op_field(
      label: label,
      field: slot,
      value: value,
      input_type: input_type,
      to_msg: OpFieldEdited,
    )
  }
  let form = state.form
  case state.kind {
    ui.OpReviseRateCard -> [
      field("Level", ui.FLevel, "number", form.level),
      field("Day rate", ui.FDayRate, "number", form.day_rate),
      field("Effective", ui.FEffective, "date", form.effective),
    ]
    ui.OpAdjustRateForPortion -> [
      field("Level", ui.FLevel, "number", form.level),
      field("Day rate", ui.FDayRate, "number", form.day_rate),
      field("Valid from", ui.FValidFrom, "date", form.valid_from),
      field("Valid to", ui.FValidTo, "date", form.valid_to),
    ]
    ui.OpSetSalary -> [
      field("Level", ui.FLevel, "number", form.level),
      field("Monthly salary", ui.FMonthlySalary, "number", form.monthly_salary),
      field("Effective", ui.FEffective, "date", form.effective),
    ]
    _ -> []
  }
}

/// The rejection sentence for the last submit attempt, or nothing.
fn op_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      html.p([attribute.class("op-form__error")], [html.text(message)])
  }
}
