//// The Board page (FR-BD*): the org board as of the global rail date, grouped by
//// project with separate On-leave and Unassigned panels, an as-of stats hero, and
//// contextual writes (AssignToProject via "+ Assign", RollOff per engineer card)
//// driven through the shared `ui` op-form engine and posted via `api`.
////
//// Two fetches answer one date: `GET /api/board?date=` (the snapshot — rows +
//// leave balances) and `GET /api/roster?as_of=` (the directory of employed
//// engineers, active projects, and clients as `Ref`s — id + name). The roster
//// resolves an engineer NAME -> id so a card can `Navigate(route.People(Some(id)))`
//// (FR-BD5) and a project TITLE -> id, and supplies the engineer/project `Ref`s the
//// op forms select over.
////
//// Each fetch result carries the `as_of` it answers; `update` drops a result whose
//// `as_of` no longer matches the model's current date (stale-while-revalidate) so a
//// fast scrub never clobbers a fresh view or a half-typed op form.

import client/api
import client/page.{type OutMsg, Navigate, OperationCommitted}
import client/route
import client/time
import client/ui
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import gleam/time/calendar
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/board/view.{
  type BoardRow, type BoardSnapshot, type UnstaffedProject, BoardRow, OnLeave,
  OnProject, Unassigned, UnstaffedProject,
} as board_view
import shared/command.{type Event}
import shared/money
import shared/roster/view.{type Ref, type Roster} as roster_view

// --- Model -------------------------------------------------------------------

/// The page's state. The board snapshot and the roster directory are fetched
/// separately for the same date; the board only renders in full once BOTH have
/// arrived, so `data` holds each as it lands. The op form, when open, holds the
/// chosen `OpKind`, the in-progress `OpForm`, and the last submit error.
pub type Model {
  Model(as_of: calendar.Date, actor: String, data: Data, op: Option(OpState))
}

/// The two fetches that answer the current `as_of`. Either may still be in flight
/// (`None`) or have failed (`Error(message)`); the view shows a loading or failed
/// state until both are `Ok`.
pub type Data {
  Data(
    snapshot: Option(Result(BoardSnapshot, String)),
    roster: Option(Result(Roster, String)),
  )
}

/// An open contextual operation: which write, the form being filled, and the last
/// rejection message (empty until a submit is refused).
pub type OpState {
  OpState(kind: ui.OpKind, form: ui.OpForm, error: String)
}

// --- Messages ----------------------------------------------------------------

/// The page's messages, wrapped by the shell as `BoardMsg(board.Msg)`. Each fetch
/// result tags the `as_of` it answers for the staleness guard.
pub type Msg {
  BoardFetched(
    as_of: calendar.Date,
    result: Result(BoardSnapshot, rsvp.Error(String)),
  )
  RosterFetched(
    as_of: calendar.Date,
    result: Result(Roster, rsvp.Error(String)),
  )
  CardClicked(engineer: String)
  OpStarted(kind: ui.OpKind)
  OpStartedFor(kind: ui.OpKind, engineer_id: Int, project_id: Int)
  OpStartedForProject(project_id: Int)
  OpFieldEdited(field: ui.OpField, value: String)
  OpCancelled
  OpSubmitted
  OpResolved(result: Result(List(Event), rsvp.Error(String)))
}

// --- Init / refetch ----------------------------------------------------------

/// Build the page's initial state for `as_of` and kick off both fetches. The
/// Board has no detail sub-view, so the `route` payload is ignored.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let _ = route
  let model =
    Model(as_of:, actor:, data: Data(snapshot: None, roster: None), op: None)
  #(model, fetch_all(as_of))
}

/// Re-fetch the board and roster for a new `as_of`, keeping the currently-shown
/// data on screen until the new responses arrive (stale-while-revalidate) and
/// WITHOUT dropping a half-typed op form. Advancing `model.as_of` makes the staleness
/// guard in `update` drop any still-in-flight responses for the previous date.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, as_of:, actor:), fetch_all(as_of))
}

fn fetch_all(as_of: calendar.Date) -> Effect(Msg) {
  effect.batch([fetch_board(as_of), fetch_roster(as_of)])
}

fn fetch_board(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/board?date=" <> time.iso_date(as_of),
    board_view.board_snapshot_decoder(),
    fn(result) { BoardFetched(as_of:, result:) },
  )
}

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/roster?as_of=" <> time.iso_date(as_of),
    roster_view.roster_decoder(),
    fn(result) { RosterFetched(as_of:, result:) },
  )
}

// --- Update ------------------------------------------------------------------

/// Fold a page message into the model, returning any cross-page `OutMsg`s.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    BoardFetched(as_of:, result:) ->
      case as_of == model.as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let snapshot = case result {
            Ok(snapshot) -> Ok(snapshot)
            Error(error) -> Error(api.describe_error(error))
          }
          let data = Data(..model.data, snapshot: Some(snapshot))
          #(Model(..model, data:), effect.none(), [])
        }
      }

    RosterFetched(as_of:, result:) ->
      case as_of == model.as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let roster = case result {
            Ok(roster) -> Ok(roster)
            Error(error) -> Error(api.describe_error(error))
          }
          let data = Data(..model.data, roster: Some(roster))
          #(Model(..model, data:), effect.none(), [])
        }
      }

    CardClicked(engineer:) ->
      case engineer_id_for(model, engineer) {
        Some(id) -> #(model, effect.none(), [Navigate(route.People(Some(id)))])
        None -> #(model, effect.none(), [])
      }

    OpStarted(kind:) -> {
      let form = ui.blank_op_form(kind:, default_date: model.as_of)
      let form = reconcile(model, form)
      #(
        Model(..model, op: Some(OpState(kind:, form:, error: ""))),
        effect.none(),
        [],
      )
    }

    OpStartedFor(kind:, engineer_id:, project_id:) -> {
      let form = ui.blank_op_form(kind:, default_date: model.as_of)
      let form =
        ui.update_op_form(form, ui.FEngineerId, int.to_string(engineer_id))
      let form =
        ui.update_op_form(form, ui.FProjectId, int.to_string(project_id))
      let form = reconcile(model, form)
      #(
        Model(..model, op: Some(OpState(kind:, form:, error: ""))),
        effect.none(),
        [],
      )
    }

    OpStartedForProject(project_id:) -> {
      let kind = ui.OpAssignToProject
      let form = ui.blank_op_form(kind:, default_date: model.as_of)
      let form =
        ui.update_op_form(form, ui.FProjectId, int.to_string(project_id))
      let form = reconcile(model, form)
      #(
        Model(..model, op: Some(OpState(kind:, form:, error: ""))),
        effect.none(),
        [],
      )
    }

    OpFieldEdited(field:, value:) ->
      case model.op {
        None -> #(model, effect.none(), [])
        Some(state) -> {
          let form = ui.update_op_form(state.form, field, value)
          #(
            Model(..model, op: Some(OpState(..state, form:, error: ""))),
            effect.none(),
            [],
          )
        }
      }

    OpCancelled -> #(Model(..model, op: None), effect.none(), [])

    OpSubmitted ->
      case model.op {
        None -> #(model, effect.none(), [])
        Some(state) ->
          case ui.build_command(state.kind, state.form) {
            Error(prompt) -> #(
              Model(..model, op: Some(OpState(..state, error: prompt))),
              effect.none(),
              [],
            )
            Ok(command) -> #(
              model,
              api.submit_operation(command, OpResolved),
              [],
            )
          }
      }

    OpResolved(result:) ->
      case result {
        Ok(_events) -> {
          let #(next, eff) = refetch(model, model.as_of, model.actor)
          #(Model(..next, op: None), eff, [OperationCommitted])
        }
        Error(error) ->
          case model.op {
            None -> #(model, effect.none(), [])
            Some(state) -> #(
              Model(
                ..model,
                op: Some(OpState(..state, error: api.describe_error(error))),
              ),
              effect.none(),
              [],
            )
          }
      }
  }
}

/// Snap an op form's engineer and project slots to valid options from the as-of
/// roster, so a freshly opened form (whether blank or pre-filled from a card) names
/// an engineer and project the directory actually carries.
fn reconcile(model: Model, form: ui.OpForm) -> ui.OpForm {
  ui.reconcile_form(form, engineer_refs(model), project_refs(model))
}

/// The engineer id for a board engineer NAME, resolved through the as-of roster
/// (the snapshot's `BoardRow` carries no id). `None` when the roster has not
/// loaded or the name is absent.
fn engineer_id_for(model: Model, engineer: String) -> Option(Int) {
  case model.data.roster {
    Some(Ok(roster)) ->
      roster.engineers
      |> list.find(fn(reference) { reference.name == engineer })
      |> option.from_result
      |> option.map(fn(reference) { reference.id })
    _ -> None
  }
}

/// The project id for a board project TITLE, resolved through the as-of roster
/// (the snapshot's `OnProject` engagement carries the title, not the id). `None`
/// when the roster has not loaded or the title is absent.
fn project_id_for(model: Model, title: String) -> Option(Int) {
  case model.data.roster {
    Some(Ok(roster)) ->
      roster.projects
      |> list.find(fn(reference) { reference.name == title })
      |> option.from_result
      |> option.map(fn(reference) { reference.id })
    _ -> None
  }
}

// --- View --------------------------------------------------------------------

/// Render the board for `as_of`: while either fetch is in flight, a loading state;
/// if either failed, the failure; otherwise the stats hero, the per-project blocks,
/// and the On-leave / Unassigned panels, with the op-form modal overlaid when open.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  case model.data.snapshot, model.data.roster {
    Some(Error(message)), _ -> view_failed(message)
    _, Some(Error(message)) -> view_failed(message)
    Some(Ok(snapshot)), Some(Ok(_roster)) -> view_loaded(model, snapshot)
    _, _ -> view_loading()
  }
}

fn view_loading() -> Element(Msg) {
  html.div([], [
    head(),
    ui.empty_state(message: "Loading the board…"),
  ])
}

fn view_failed(message: String) -> Element(Msg) {
  html.div([], [
    head(),
    ui.empty_state(message: "Could not load the board: " <> message),
  ])
}

fn head() -> Element(Msg) {
  ui.page_head(
    title: "Board",
    blurb: "The whole consultancy as it stands on the selected date. Scrub the timeline to watch allocations, leave, and run-rate change.",
    actions: [
      ui.button(
        label: "+ Assign",
        kind: ui.Primary,
        size: ui.Medium,
        on_press: OpStarted(ui.OpAssignToProject),
      ),
    ],
  )
}

fn view_loaded(model: Model, snapshot: BoardSnapshot) -> Element(Msg) {
  let on_project = list.filter(snapshot.rows, is_on_project)
  let on_leave = list.filter(snapshot.rows, is_on_leave)
  let unassigned = list.filter(snapshot.rows, is_unassigned)
  html.div([], [
    head(),
    stats_hero(on_project, on_leave, snapshot),
    on_projects_panel(model, on_project),
    unstaffed_projects_panel(model, snapshot.unstaffed),
    on_leave_panel(on_leave),
    unassigned_panel(unassigned),
    op_panel(model),
  ])
}

// --- Stats hero --------------------------------------------------------------

/// The four as-of stat cards recomputed from the snapshot: employed headcount,
/// utilization (Σ billable fraction ÷ headcount), on-leave count, and billable
/// run-rate (Σ fraction × day_rate per day).
fn stats_hero(
  on_project: List(BoardRow),
  on_leave: List(BoardRow),
  snapshot: BoardSnapshot,
) -> Element(Msg) {
  let headcount =
    snapshot.rows
    |> list.map(fn(row) { row.engineer })
    |> set.from_list
    |> set.size
  let billable_fraction =
    list.fold(on_project, 0.0, fn(sum, row) { sum +. fraction_of(row) })
  let utilization = case headcount {
    0 -> 0
    count -> float.round(billable_fraction /. int.to_float(count) *. 100.0)
  }
  let day_revenue =
    money.sum(
      list.map(on_project, fn(row) {
        money.scale_by(day_rate_of(row), fraction_of(row))
      }),
    )
  html.div([attribute.class("stats")], [
    ui.stat(
      value: int.to_string(headcount),
      unit: "people",
      label: "Employed",
      pct: ui.NoPct,
    ),
    ui.stat(
      value: int.to_string(utilization) <> "%",
      unit: "",
      label: "Utilization",
      pct: ui.Pct(utilization),
    ),
    ui.stat(
      value: int.to_string(list.length(on_leave)),
      unit: "on leave",
      label: "On leave",
      pct: ui.NoPct,
    ),
    ui.stat(
      value: ui.money_k(money.to_float(day_revenue)),
      unit: "/day",
      label: "Billable run-rate",
      pct: ui.NoPct,
    ),
  ])
}

// --- On-projects panel -------------------------------------------------------

/// The "On projects" panel: each project a `.board-group` (swatch, title, client,
/// run-rate + team-size meta) over a grid of engineer allocation cards.
fn on_projects_panel(model: Model, on_project: List(BoardRow)) -> Element(Msg) {
  let groups = group_by_project(on_project)
  let allocation_count = list.length(on_project)
  let project_count = list.length(groups)
  let count =
    int.to_string(allocation_count)
    <> " allocations · "
    <> int.to_string(project_count)
    <> " projects"
  let body = case groups {
    [] -> [ui.empty_state(message: "No one is allocated on this date.")]
    groups ->
      list.index_map(groups, fn(group, index) {
        proj_block(model, group, index)
      })
  }
  ui.panel(title: "On projects", count: count, right: [], body: body)
}

/// One project's block of engineer cards. `category` (the group's index) tints the
/// swatch; the meta line shows the project's daily run-rate and team size.
fn proj_block(
  model: Model,
  group: #(String, String, List(BoardRow)),
  category: Int,
) -> Element(Msg) {
  let #(project, client, rows) = group
  let project_revenue =
    money.sum(
      list.map(rows, fn(row) {
        money.scale_by(day_rate_of(row), fraction_of(row))
      }),
    )
  let meta =
    ui.money_k(money.to_float(project_revenue))
    <> "/day · "
    <> int.to_string(list.length(rows))
    <> " on team"
  let cards = list.map(rows, fn(row) { project_card(model, project, row) })
  html.div([attribute.class("board-group")], [
    html.div([attribute.class("board-group__head")], [
      ui.swatch(category: category, inline: False),
      html.span([attribute.class("board-group__title")], [html.text(project)]),
      html.span([attribute.class("board-group__client")], [html.text(client)]),
      html.span([attribute.class("board-group__meta")], [html.text(meta)]),
    ]),
    html.div([attribute.class("board-grid")], cards),
  ])
}

/// An engineer's allocation card on a project: avatar, name, a sub-line of
/// fraction / short-level / day-rate chips, and a right-aligned "Roll off"
/// action. Clicking the card drills into the engineer's detail; "Roll off" opens a
/// modal pre-filled with the engineer and this project.
fn project_card(model: Model, project: String, row: BoardRow) -> Element(Msg) {
  let sub = case row.engagement {
    OnProject(day_rate:, fraction:, ..) -> [
      ui.chip(label: ui.fraction(fraction), tone: ui.Accent),
      ui.chip(label: short_level(row.level), tone: ui.Neutral),
      ui.chip(label: ui.money(money.to_float(day_rate)) <> "/d", tone: ui.Neutral),
    ]
    _ -> []
  }
  alloc_card(row, "", sub, roll_off_action(model, project, row))
}

/// The "Roll off" affordance on a project card. It opens a RollOff modal pre-filled
/// with the engineer's id (resolved by name) and this project's id (resolved by
/// title) from the as-of roster. Renders nothing until BOTH resolve.
/// `stop_propagation` keeps the click off the card's drill-in handler.
fn roll_off_action(
  model: Model,
  project: String,
  row: BoardRow,
) -> Element(Msg) {
  case engineer_id_for(model, row.engineer), project_id_for(model, project) {
    Some(engineer_id), Some(project_id) ->
      html.button(
        [
          attribute.class("btn btn--ghost btn--sm"),
          event.stop_propagation(
            event.on_click(OpStartedFor(
              kind: ui.OpRollOff,
              engineer_id:,
              project_id:,
            )),
          ),
        ],
        [html.text("Roll off")],
      )
    _, _ -> element.none()
  }
}

// --- Unstaffed-projects panel ------------------------------------------------

/// The "Unstaffed projects" panel: one card per active project with no engineer
/// allocated on this date. Absent on a fully-staffed day (`[] -> element.none()`).
/// Each card shows the project title, the client as a sub-line, and a right-aligned
/// "Assign" button that opens the canonical AssignToProject modal pre-filled with
/// this project (engineer/fraction left for the user).
fn unstaffed_projects_panel(
  model: Model,
  unstaffed: List(UnstaffedProject),
) -> Element(Msg) {
  let _ = model
  case unstaffed {
    [] -> element.none()
    projects -> {
      let cards = list.map(projects, unstaffed_card)
      ui.panel(
        title: "Unstaffed projects",
        count: unstaffed_count(list.length(projects)),
        right: [],
        body: [
          html.div([attribute.class("board-group")], [
            html.div([attribute.class("board-grid")], cards),
          ]),
        ],
      )
    }
  }
}

/// The count header for the unstaffed panel: "1 project" / "<n> projects".
fn unstaffed_count(count: Int) -> String {
  case count {
    1 -> "1 project"
    n -> int.to_string(n) <> " projects"
  }
}

/// One unstaffed-project card: the title, the client sub-line, and a right-aligned
/// "Assign" button opening the AssignToProject modal pre-filled with this project.
fn unstaffed_card(project: UnstaffedProject) -> Element(Msg) {
  let UnstaffedProject(project_id:, title:, client:) = project
  html.div([attribute.class("board-card")], [
    html.div([attribute.class("board-card__info")], [
      html.div([attribute.class("board-card__name")], [html.text(title)]),
      html.div([attribute.class("board-card__sub")], [html.text(client)]),
    ]),
    html.div([attribute.class("board-card__action")], [
      ui.button(
        label: "Assign",
        kind: ui.Ghost,
        size: ui.Small,
        on_press: OpStartedForProject(project_id:),
      ),
    ]),
  ])
}

// --- On-leave / Unassigned panels --------------------------------------------

/// The "On leave" panel: one card per on-leave engineer, the sub-line showing the
/// leave kind and the date it runs until.
fn on_leave_panel(on_leave: List(BoardRow)) -> Element(Msg) {
  case on_leave {
    [] -> element.none()
    rows -> {
      let cards =
        list.map(rows, fn(row) {
          let sub = case row.engagement {
            OnLeave(kind:, valid_to:, ..) -> [
              html.span([attribute.class("board-card__fraction")], [
                html.text(kind),
              ]),
              html.span([], [html.text("til " <> time.format_date(valid_to))]),
            ]
            _ -> []
          }
          alloc_card(row, "on-leave", sub, element.none())
        })
      ui.panel(
        title: "On leave",
        count: int.to_string(list.length(rows)),
        right: [],
        body: [
          html.div([attribute.class("board-group")], [
            html.div([attribute.class("board-grid")], cards),
          ]),
        ],
      )
    }
  }
}

/// The "Unassigned" (bench) panel: one card per employed-but-unallocated engineer,
/// the sub-line showing their level band and "available".
fn unassigned_panel(unassigned: List(BoardRow)) -> Element(Msg) {
  case unassigned {
    [] -> element.none()
    rows -> {
      let cards =
        list.map(rows, fn(row) {
          let sub = [
            ui.chip(label: short_level(row.level), tone: ui.Neutral),
            html.span([], [html.text("available")]),
          ]
          alloc_card(row, "bench", sub, element.none())
        })
      ui.panel(
        title: "Unassigned",
        count: int.to_string(list.length(rows)),
        right: [],
        body: [
          html.div([attribute.class("board-group")], [
            html.div([attribute.class("board-grid")], cards),
          ]),
        ],
      )
    }
  }
}

/// One `.board-card`: a flex row of avatar, an info column (name + badge sub-line),
/// and a right-aligned `action` slot, tinted by the engineer's name hash, with the
/// `extra` modifier ("" | "on-leave" | "bench"). The action is its own element after
/// the info so CSS pushes it to the far right; pass `element.none()` for no action.
/// Clicking the card drills into the engineer detail.
fn alloc_card(
  row: BoardRow,
  extra: String,
  sub: List(Element(Msg)),
  action: Element(Msg),
) -> Element(Msg) {
  let class = case extra {
    "" -> "board-card"
    extra -> "board-card board-card--" <> extra
  }
  html.div([attribute.class(class), event.on_click(CardClicked(row.engineer))], [
    ui.avatar(
      name: row.engineer,
      category: name_category(row.engineer),
      class: "avatar",
    ),
    html.div([attribute.class("board-card__info")], [
      html.div([attribute.class("board-card__name")], [html.text(row.engineer)]),
      html.div([attribute.class("board-card__sub")], sub),
    ]),
    html.div([attribute.class("board-card__action")], [action]),
  ])
}

// --- Op form panel -----------------------------------------------------------

/// The contextual operation, shown as a centred modal over a dimmed backdrop when an
/// op is open. Renders the fields the op needs (engineer/project as `<select>`s from
/// the as-of directory, fraction, dates), the last rejection message, and the
/// Cancel / Confirm footer. Clicking the backdrop or Cancel closes (`OpCancelled`);
/// Confirm submits (`OpSubmitted`).
fn op_panel(model: Model) -> Element(Msg) {
  case model.op {
    None -> element.none()
    Some(state) ->
      ui.modal(
        title: op_title(state.kind),
        error: state.error,
        body: op_fields(model, state),
        on_cancel: OpCancelled,
        on_confirm: OpSubmitted,
        confirm_label: op_verb(state.kind),
      )
  }
}

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpAssignToProject -> "Assign to a project"
    ui.OpRollOff -> "Roll off a project"
    _ -> "Operation"
  }
}

fn op_verb(kind: ui.OpKind) -> String {
  case kind {
    ui.OpAssignToProject -> "Assign"
    ui.OpRollOff -> "Roll off"
    _ -> "Confirm"
  }
}

/// The form fields for the open op. Both the engineer and the project are picked
/// from the as-of roster (`ref_select`), pre-filled from the launching card.
/// AssignToProject adds a fraction and a validity window; RollOff adds an effective
/// date.
fn op_fields(model: Model, state: OpState) -> List(Element(Msg)) {
  let engineer_field =
    ui.ref_select(
      label: "Engineer",
      field: ui.FEngineerId,
      refs: engineer_refs(model),
      selected: state.form.engineer_id,
      to_msg: OpFieldEdited,
    )
  let project_field =
    ui.ref_select(
      label: "Project",
      field: ui.FProjectId,
      refs: project_refs(model),
      selected: state.form.project_id,
      to_msg: OpFieldEdited,
    )
  case state.kind {
    ui.OpAssignToProject -> [
      engineer_field,
      project_field,
      ui.op_field(
        label: "Fraction",
        field: ui.FFraction,
        value: state.form.fraction,
        input_type: "number",
        to_msg: OpFieldEdited,
      ),
      ui.op_field(
        label: "Valid from",
        field: ui.FValidFrom,
        value: state.form.valid_from,
        input_type: "date",
        to_msg: OpFieldEdited,
      ),
      ui.op_field(
        label: "Valid to",
        field: ui.FValidTo,
        value: state.form.valid_to,
        input_type: "date",
        to_msg: OpFieldEdited,
      ),
    ]
    _ -> [
      engineer_field,
      project_field,
      ui.op_field(
        label: "Effective",
        field: ui.FEffective,
        value: state.form.effective,
        input_type: "date",
        to_msg: OpFieldEdited,
      ),
    ]
  }
}

// --- Directories (Ref lists for op selects) ----------------------------------

/// The engineer directory for the op `<select>`s, from the as-of roster (every
/// employed engineer, id + name). Empty until the roster loads.
fn engineer_refs(model: Model) -> List(Ref) {
  case model.data.roster {
    Some(Ok(roster)) -> roster.engineers
    _ -> []
  }
}

/// The project directory for the op `<select>`s, from the as-of roster (every
/// active project, id + name). Empty until the roster loads.
fn project_refs(model: Model) -> List(Ref) {
  case model.data.roster {
    Some(Ok(roster)) -> roster.projects
    _ -> []
  }
}

// --- Snapshot helpers --------------------------------------------------------

fn is_on_project(row: BoardRow) -> Bool {
  case row.engagement {
    OnProject(..) -> True
    _ -> False
  }
}

fn is_on_leave(row: BoardRow) -> Bool {
  case row.engagement {
    OnLeave(..) -> True
    _ -> False
  }
}

fn is_unassigned(row: BoardRow) -> Bool {
  case row.engagement {
    Unassigned -> True
    _ -> False
  }
}

fn fraction_of(row: BoardRow) -> Float {
  case row.engagement {
    OnProject(fraction:, ..) -> fraction
    _ -> 0.0
  }
}

fn day_rate_of(row: BoardRow) -> money.Money {
  case row.engagement {
    OnProject(day_rate:, ..) -> day_rate
    _ -> money.zero()
  }
}

/// Group on-project rows by project, preserving first-seen order. Each group is
/// `#(project, client, rows)`.
fn group_by_project(
  rows: List(BoardRow),
) -> List(#(String, String, List(BoardRow))) {
  let order =
    rows
    |> list.filter_map(fn(row) {
      case row.engagement {
        OnProject(project:, ..) -> Ok(project)
        _ -> Error(Nil)
      }
    })
    |> list.unique
  list.map(order, fn(project) {
    let matching =
      list.filter(rows, fn(row) {
        case row.engagement {
          OnProject(project: row_project, ..) -> row_project == project
          _ -> False
        }
      })
    let client = case matching {
      [BoardRow(engagement: OnProject(client:, ..), ..), ..] -> client
      _ -> ""
    }
    #(project, client, matching)
  })
}

// --- Small presentation helpers ----------------------------------------------

/// A stable categorical index for an engineer name, so the same person keeps the
/// same avatar tint as the board re-renders. Sums the name's codepoints.
fn name_category(name: String) -> Int {
  string.to_utf_codepoints(name)
  |> list.fold(0, fn(sum, codepoint) {
    sum + string.utf_codepoint_to_int(codepoint)
  })
}

/// The board's short level label ("L6"), the dense card form of the People
/// detail's full `ui.level_band` ("L6 · Distinguished").
fn short_level(level: Int) -> String {
  "L" <> int.to_string(level)
}
