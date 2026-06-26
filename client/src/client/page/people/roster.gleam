//// The People roster list (FR-PE*), a self-contained sub-component MVU split out
//// of `client/page/people`. This is the page's LIST mode: it owns its own `Model`
//// (its as-of, the roster list load state, the as-of operations directory, and the
//// open Onboard-engineer op form), its own `Msg`, its `init`/`update`, and its
//// `view`.
////
//// It reads `GET /api/people?as_of=` for the roster and `GET /api/roster?as_of=`
//// for the op-form directory; each result carries the `as_of` it answers so a stale
//// reply is dropped. Its one write is OnboardEngineer; submitting posts via
//// `api.submit_operation` and, on success, raises `OperationCommitted` and
//// refetches. Clicking a row raises `Navigate(People(Some(id)))` so the shell owns
//// the URL (the detail mode is a different sub-component).

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/time
import client/ui
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/command.{type Event}
import shared/money
import shared/people/view.{
  type PeopleList, type PersonRow, type RosterStatus, PeopleList, PersonRow,
  RosterOnLeave, RosterOnProjects, RosterUnassigned,
} as people_view
import shared/roster/view.{type Ref, type Roster} as roster_view

/// The roster list's state: the as-of its data answers, the roster list load
/// state, the as-of operations directory (project/engineer `Ref`s for the op
/// form), and the open Onboard-engineer op form (or `None`).
pub type Model {
  Model(
    as_of: calendar.Date,
    people: Load,
    roster: Directory,
    op: Option(ui.OpState),
  )
}

/// The roster list's load state.
pub type Load {
  Loading
  Loaded(people: List(PersonRow))
  Failed(message: String)
}

/// The as-of operations directory's load state.
pub type Directory {
  DirectoryLoading
  DirectoryLoaded(roster: Roster)
  DirectoryFailed(message: String)
}

/// The list mode's messages: the roster and directory fetch results (each carrying
/// the `as_of` they answer), the row-open navigation, the Onboard op lifecycle, and
/// the operation reply.
pub type Msg {
  RosterFetched(
    as_of: calendar.Date,
    result: Result(PeopleList, rsvp.Error(String)),
  )
  DirectoryFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  RowClicked(engineer_id: Int)
  OpOpened(kind: ui.OpKind)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  OperationReturned(result: Result(List(Event), rsvp.Error(String)))
}

/// Start the list mode at `as_of`, fetching the roster and the directory.
pub fn init(as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  let model =
    Model(as_of:, people: Loading, roster: DirectoryLoading, op: None)
  #(model, effect.batch([fetch_roster(as_of), fetch_directory(as_of)]))
}

/// Re-fetch the list mode for a new `as_of` (stale-while-revalidate), keeping any
/// open op form.
pub fn refetch(model: Model, as_of: calendar.Date) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, as_of:, people: Loading, roster: DirectoryLoading),
    effect.batch([fetch_roster(as_of), fetch_directory(as_of)]),
  )
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/people?as_of=" <> time.iso_date(as_of),
    people_view.people_list_decoder(),
    fn(result) { RosterFetched(as_of:, result:) },
  )
}

fn fetch_directory(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { DirectoryFetched(as_of:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    RosterFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let people = case result {
            Ok(PeopleList(people:, ..)) -> Loaded(people:)
            Error(error) -> Failed(message: api.describe_error(error))
          }
          #(Model(..model, people:), effect.none(), [])
        }
      }

    DirectoryFetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> DirectoryLoaded(roster:)
            Error(error) -> DirectoryFailed(message: api.describe_error(error))
          }
          #(Model(..model, roster:), effect.none(), [])
        }
      }

    RowClicked(engineer_id:) -> #(model, effect.none(), [
      Navigate(route.People(id: Some(engineer_id))),
    ])

    OpOpened(kind:) -> #(
      Model(
        ..model,
        op: Some(ui.OpState(kind:, form: blank_form(model, kind), error: None)),
      ),
      effect.none(),
      [],
    )

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) -> #(
          Model(
            ..model,
            op: Some(ui.OpState(
              kind:,
              form: ui.update_op_form(form, field, value),
              error: None,
            )),
          ),
          effect.none(),
          [],
        )
        None -> #(model, effect.none(), [])
      }

    OpSubmitted ->
      case model.op {
        Some(ui.OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              Model(
                ..model,
                op: Some(ui.OpState(kind:, form:, error: Some(prompt))),
              ),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch) = refetch(Model(..model, op: None), model.as_of)
          #(refreshed, fetch, [OperationCommitted])
        }
        Error(error) -> #(
          set_op_error(model, api.describe_error(error)),
          effect.none(),
          [],
        )
      }
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case model.op {
    Some(ui.OpState(kind:, form:, ..)) ->
      Model(..model, op: Some(ui.OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

/// A fresh op form for `kind`: every entity slot snapped to a valid directory
/// option and dates defaulting to the as-of. The list mode only raises
/// OnboardEngineer, whose fields are typed free-text, so no detail prefill applies.
fn blank_form(model: Model, kind: ui.OpKind) -> ui.OpForm {
  let form = ui.blank_op_form(kind, model.as_of)
  ui.reconcile_form(form, [], project_refs(model))
}

/// The active project `Ref`s from the loaded directory, for the op-form
/// `<select>`s. Empty until the directory loads.
fn project_refs(model: Model) -> List(Ref) {
  case model.roster {
    DirectoryLoaded(roster:) -> roster.projects
    _ -> []
  }
}

// --- View -------------------------------------------------------------------

/// Render the list mode: the page head with the Onboard action, the op modal, and
/// the roster panel (its own loading / failed guards).
pub fn view(model: Model) -> Element(Msg) {
  let head =
    ui.page_head(
      title: "People",
      blurb: "Everyone employed as of "
        <> time.iso_date(model.as_of)
        <> ". Open a person for their full record and history.",
      actions: [op_button("+ Onboard", ui.OpOnboardEngineer, False)],
    )
  let op_modal = view_op_modal(model.op)
  case model.people {
    Loading -> column([head, op_modal, ui.empty_state("Loading roster…")])
    Failed(message:) ->
      column([
        head,
        op_modal,
        ui.empty_state("Could not load the roster: " <> message),
      ])
    Loaded(people:) ->
      column([head, op_modal, panel(people, on_open: RowClicked)])
  }
}

fn column(children: List(Element(Msg))) -> Element(Msg) {
  html.div([], children)
}

/// A button that opens the contextual operation `kind`. `ghost` renders the
/// secondary (outlined) variant.
fn op_button(label: String, kind: ui.OpKind, ghost: Bool) -> Element(Msg) {
  let button_kind = case ghost {
    True -> ui.Ghost
    False -> ui.Primary
  }
  ui.button(label:, kind: button_kind, size: ui.Small, on_press: OpOpened(kind))
}

/// The Onboard-engineer op as a centred modal, shown only while open. The list
/// mode raises only OnboardEngineer, so the modal is fixed to that op.
fn view_op_modal(op: Option(ui.OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(ui.OpState(form:, error:, ..)) ->
      ui.modal(
        title: "Onboard an engineer",
        error: option.unwrap(error, ""),
        body: op_fields(form),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: "Onboard",
      )
  }
}

fn op_fields(form: ui.OpForm) -> List(Element(Msg)) {
  [
    text_field("Name", ui.FName, form.name),
    number_field("Level", ui.FLevel, form.level),
    date_field("Effective", ui.FEffective, form.effective),
  ]
}

fn text_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "text",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn number_field(
  label: String,
  field: ui.OpField,
  value: String,
) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "number",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

fn date_field(label: String, field: ui.OpField, value: String) -> Element(Msg) {
  ui.op_field(
    label:,
    field:,
    value:,
    input_type: "date",
    to_msg: fn(field, value) { OpFieldEdited(field:, value:) },
  )
}

/// The roster panel: a table of everyone employed on the date (engineer, level,
/// status, allocation, leave balance, day rate), or an empty-state when none are.
/// `on_open(engineer_id)` is raised when a row is clicked.
pub fn panel(
  people: List(PersonRow),
  on_open on_open: fn(Int) -> msg,
) -> Element(msg) {
  let rows = list.map(people, fn(person) { roster_row(person, on_open) })
  let body = case people {
    [] -> [ui.empty_state("No engineers employed on this date.")]
    _ -> [
      ui.data_table(
        headers: [
          #("Engineer", False),
          #("Level", False),
          #("Status", False),
          #("Allocated", True),
          #("Annual lv.", True),
          #("Day rate", True),
        ],
        rows:,
      ),
    ]
  }
  ui.panel(
    title: "Roster",
    count: int.to_string(list.length(people)),
    right: [],
    body:,
  )
}

fn roster_row(person: PersonRow, on_open: fn(Int) -> msg) -> Element(msg) {
  let PersonRow(
    engineer_id:,
    name:,
    email:,
    level:,
    status:,
    allocated_fraction:,
    annual_balance:,
    day_rate:,
  ) = person
  let #(variant, label) = status_pill(status)
  let allocated = case status {
    RosterOnProjects(..) -> ui.fraction(allocated_fraction)
    _ -> "—"
  }
  html.tr([attribute.class("clickable"), event.on_click(on_open(engineer_id))], [
    html.td([], [name_cell(engineer_id, name, email)]),
    html.td([], [
      html.span([attribute.class("level-pill")], [
        html.text(ui.level_band(level)),
      ]),
    ]),
    html.td([], [ui.pill(variant:, label:)]),
    html.td([attribute.class("num")], [html.text(allocated)]),
    html.td([attribute.class("num")], [html.text(ui.days(annual_balance))]),
    html.td([attribute.class("num")], [
      html.text(ui.money(money.to_float(day_rate))),
    ]),
  ])
}

fn name_cell(engineer_id: Int, name: String, email: String) -> Element(msg) {
  html.div([attribute.class("cell-name")], [
    ui.avatar(name:, category: engineer_id, class: "avatar"),
    html.div([], [
      html.div([attribute.class("cell-name__name")], [html.text(name)]),
      html.div([attribute.class("cell-sub")], [html.text(email)]),
    ]),
  ])
}

/// The pill variant and label for a roster status: on-projects is "active" with
/// the project titles, on-leave is "issued" (the amber pill) with the leave
/// kind, unassigned is "ended". Mirrors the prototype's status classes.
fn status_pill(status: RosterStatus) -> #(String, String) {
  case status {
    RosterOnProjects(projects:) -> #("active", join_titles(projects))
    RosterOnLeave(kind:) -> #("issued", "On " <> kind <> " leave")
    RosterUnassigned -> #("ended", "Unassigned")
  }
}

fn join_titles(titles: List(String)) -> String {
  case titles {
    [] -> "On projects"
    _ -> string.join(titles, ", ")
  }
}
