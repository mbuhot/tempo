//// The Board page (FR-BD*): the org board as of the global rail date, grouped by
//// project with separate On-leave and Unassigned panels, an as-of stats hero, and
//// contextual writes (AssignToProject via "+ Assign", RollOff per engineer card)
//// driven through the shared `ui` op-form engine and posted via `api`.
////
//// Two fetches answer one date: `GET /api/board?date=` (the snapshot — rows +
//// leave balances) and `GET /api/people?as_of=` (the roster, whose `PersonRow`
//// carries the `engineer_id` the snapshot's `BoardRow` lacks). The people list
//// resolves an engineer NAME -> id so a card can `Navigate(route.People(Some(id)))`
//// (FR-BD5) and supplies the engineer/project `Ref`s the op forms select over.
////
//// Each fetch result carries the `as_of` it answers; `update` drops a result whose
//// `as_of` no longer matches the model's current date (stale-while-revalidate) so a
//// fast scrub never clobbers a fresh view or a half-typed op form.

import client/api
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
import shared/codecs
import shared/types.{
  type BoardRow, type BoardSnapshot, type Event, type PeopleList, type Ref,
  BoardRow, OnLeave, OnProject, Ref, Unassigned,
}

// --- Model -------------------------------------------------------------------

/// The page's state. The board snapshot and the people roster are fetched
/// separately for the same date; `Loaded` only renders the full board once BOTH
/// have arrived, so `data` holds each as it lands. The op form, when open, holds
/// the chosen `OpKind`, the in-progress `OpForm`, and the last submit error.
pub type Model {
  Model(as_of: calendar.Date, actor: String, data: Data, op: Option(OpState))
}

/// The two fetches that answer the current `as_of`. Either may still be in flight
/// (`None`) or have failed (`Error(message)`); the view shows a loading or failed
/// state until both are `Ok`.
pub type Data {
  Data(
    snapshot: Option(Result(BoardSnapshot, String)),
    people: Option(Result(PeopleList, String)),
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
  PeopleFetched(
    as_of: calendar.Date,
    result: Result(PeopleList, rsvp.Error(String)),
  )
  CardClicked(engineer: String)
  OpStarted(kind: ui.OpKind)
  OpStartedFor(kind: ui.OpKind, engineer_id: Int)
  OpFieldEdited(field: ui.OpField, value: String)
  OpCancelled
  OpSubmitted
  OpResolved(result: Result(List(Event), rsvp.Error(String)))
}

/// The cross-page effects a page can raise: navigate to a route, or signal a write
/// committed. Identical across all 7 pages.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
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
    Model(as_of:, actor:, data: Data(snapshot: None, people: None), op: None)
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
  effect.batch([fetch_board(as_of), fetch_people(as_of)])
}

fn fetch_board(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/board?date=" <> time.iso_date(as_of),
    codecs.board_snapshot_decoder(),
    fn(result) { BoardFetched(as_of:, result:) },
  )
}

fn fetch_people(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/people?as_of=" <> time.iso_date(as_of),
    codecs.people_list_decoder(),
    fn(result) { PeopleFetched(as_of:, result:) },
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

    PeopleFetched(as_of:, result:) ->
      case as_of == model.as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let people = case result {
            Ok(people) -> Ok(people)
            Error(error) -> Error(api.describe_error(error))
          }
          let data = Data(..model.data, people: Some(people))
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

    OpStartedFor(kind:, engineer_id:) -> {
      let form = ui.blank_op_form(kind:, default_date: model.as_of)
      let form =
        ui.update_op_form(form, ui.FEngineerId, int.to_string(engineer_id))
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
              api.submit_operation(model.actor, command, OpResolved),
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

/// Seed an op form's engineer slot from the as-of roster so a freshly opened "+
/// Assign" form already names a valid engineer. The project id has no source on
/// this page's reads (neither the snapshot nor the roster carries one), so it is
/// left for manual entry.
fn reconcile(model: Model, form: ui.OpForm) -> ui.OpForm {
  ui.reconcile_form(form, engineer_refs(model), [])
}

/// The engineer id for a board engineer NAME, resolved through the people roster
/// (the snapshot's `BoardRow` carries no id). `None` when the roster has not
/// loaded or the name is absent.
fn engineer_id_for(model: Model, engineer: String) -> Option(Int) {
  case model.data.people {
    Some(Ok(people)) ->
      people.people
      |> list.find(fn(person) { person.name == engineer })
      |> option.from_result
      |> option.map(fn(person) { person.engineer_id })
    _ -> None
  }
}

// --- View --------------------------------------------------------------------

/// Render the board for `as_of`: while either fetch is in flight, a loading state;
/// if either failed, the failure; otherwise the stats hero, the per-project blocks,
/// and the On-leave / Unassigned panels, with the op-form panel overlaid when open.
pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  case model.data.snapshot, model.data.people {
    Some(Error(message)), _ -> view_failed(message)
    _, Some(Error(message)) -> view_failed(message)
    Some(Ok(snapshot)), Some(Ok(people)) -> view_loaded(model, snapshot, people)
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
    eyebrow: "Org board",
    title: "Who's doing what",
    blurb: "The whole consultancy as it stands on the selected date. Scrub the timeline to watch allocations, leave, and run-rate change.",
    actions: [
      html.button(
        [
          attribute.class("btn"),
          event.on_click(OpStarted(ui.OpAssignToProject)),
        ],
        [html.text("+ Assign")],
      ),
    ],
  )
}

fn view_loaded(
  model: Model,
  snapshot: BoardSnapshot,
  people: PeopleList,
) -> Element(Msg) {
  let on_project = list.filter(snapshot.rows, is_on_project)
  let on_leave = list.filter(snapshot.rows, is_on_leave)
  let unassigned = list.filter(snapshot.rows, is_unassigned)
  html.div([], [
    head(),
    op_panel(model),
    stats_hero(on_project, on_leave, snapshot),
    on_projects_panel(on_project, people),
    on_leave_panel(on_leave),
    unassigned_panel(unassigned),
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
    list.fold(on_project, 0.0, fn(sum, row) {
      sum +. fraction_of(row) *. day_rate_of(row)
    })
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
      value: ui.money_k(day_revenue),
      unit: "/day",
      label: "Billable run-rate",
      pct: ui.NoPct,
    ),
  ])
}

// --- On-projects panel -------------------------------------------------------

/// The "On projects" panel: each project a `.board-group` (swatch, title, client,
/// run-rate + team-size meta) over a grid of engineer allocation cards.
fn on_projects_panel(
  on_project: List(BoardRow),
  people: PeopleList,
) -> Element(Msg) {
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
        proj_block(group, index, people)
      })
  }
  ui.panel(title: "On projects", count: count, right: [], body: body)
}

/// One project's block of engineer cards. `category` (the group's index) tints the
/// swatch; the meta line shows the project's daily run-rate and team size.
fn proj_block(
  group: #(String, String, List(BoardRow)),
  category: Int,
  people: PeopleList,
) -> Element(Msg) {
  let #(project, client, rows) = group
  let project_revenue =
    list.fold(rows, 0.0, fn(sum, row) {
      sum +. fraction_of(row) *. day_rate_of(row)
    })
  let meta =
    ui.money_k(project_revenue)
    <> "/day · "
    <> int.to_string(list.length(rows))
    <> " on team"
  let cards = list.map(rows, fn(row) { project_card(row, people) })
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

/// An engineer's allocation card on a project: avatar, name, and a sub-line of
/// fraction pill / level-band pill / day rate. Clicking the card drills into the
/// engineer's detail; "Roll off" opens a pre-filled RollOff form.
fn project_card(row: BoardRow, people: PeopleList) -> Element(Msg) {
  let sub = case row.engagement {
    OnProject(day_rate:, fraction:, ..) -> [
      html.span([attribute.class("board-card__fraction")], [
        html.text(ui.fraction(fraction)),
      ]),
      html.span([attribute.class("level-pill")], [
        html.text(ui.level_band(row.level)),
      ]),
      html.span([], [html.text(ui.money(day_rate) <> "/d")]),
      roll_off_action(row, people),
    ]
    _ -> []
  }
  alloc_card(row, "", sub)
}

/// The "Roll off" affordance on a project card. It opens a RollOff form pre-filled
/// with the engineer's id (resolved via the roster); the project id is entered in
/// the form (the board's reads carry no project id). Renders nothing when the
/// engineer's id cannot be resolved. `stop_propagation` keeps the click off the
/// card's drill-in handler.
fn roll_off_action(row: BoardRow, people: PeopleList) -> Element(Msg) {
  let engineer_id =
    people.people
    |> list.find(fn(person) { person.name == row.engineer })
    |> option.from_result
    |> option.map(fn(person) { person.engineer_id })
  case engineer_id {
    Some(engineer_id) ->
      html.button(
        [
          attribute.class("btn btn--ghost btn--sm"),
          event.stop_propagation(
            event.on_click(OpStartedFor(
              kind: ui.OpRollOff,
              engineer_id: engineer_id,
            )),
          ),
        ],
        [html.text("Roll off")],
      )
    None -> element.none()
  }
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
              html.span([], [html.text("til " <> format_date(valid_to))]),
            ]
            _ -> []
          }
          alloc_card(row, "on-leave", sub)
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
            html.span([attribute.class("level-pill")], [
              html.text(ui.level_band(row.level)),
            ]),
            html.span([], [html.text("available")]),
          ]
          alloc_card(row, "bench", sub)
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

/// One `.board-card`: avatar + name + sub-line, tinted by the engineer's name hash,
/// with the `extra` modifier ("" | "on-leave" | "bench"). Clicking it drills into
/// the engineer detail.
fn alloc_card(
  row: BoardRow,
  extra: String,
  sub: List(Element(Msg)),
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
  ])
}

// --- Op form panel -----------------------------------------------------------

/// The contextual operation panel, shown when an op is open. Renders the fields the
/// op needs (engineer/project from the as-of directory, fraction, dates), the last
/// rejection message, and Apply / Cancel actions.
fn op_panel(model: Model) -> Element(Msg) {
  case model.op {
    None -> element.none()
    Some(state) -> {
      let fields = op_fields(model, state)
      let error_row = case state.error {
        "" -> element.none()
        message ->
          html.div([attribute.class("op-form__error")], [html.text(message)])
      }
      ui.panel(title: op_title(state.kind), count: "", right: [], body: [
        html.div([attribute.class("op-form")], fields),
        error_row,
        html.div([attribute.class("action-row")], [
          html.button(
            [attribute.class("btn btn--ghost"), event.on_click(OpCancelled)],
            [html.text("Cancel")],
          ),
          html.button([attribute.class("btn"), event.on_click(OpSubmitted)], [
            html.text("Apply"),
          ]),
        ]),
      ])
    }
  }
}

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpAssignToProject -> "Assign to a project"
    ui.OpRollOff -> "Roll off a project"
    _ -> "Operation"
  }
}

/// The form fields for the open op. The engineer is picked from the as-of roster
/// (`ref_select`); the project id is typed (the board's reads carry no project id
/// to populate a select). AssignToProject adds a fraction and a validity window;
/// RollOff adds an effective date.
fn op_fields(model: Model, state: OpState) -> List(Element(Msg)) {
  let engineers = engineer_refs(model)
  let engineer_field =
    ui.ref_select(
      label: "Engineer",
      field: ui.FEngineerId,
      refs: engineers,
      selected: state.form.engineer_id,
      to_msg: OpFieldEdited,
    )
  let project_field =
    ui.op_field(
      label: "Project id",
      field: ui.FProjectId,
      value: state.form.project_id,
      input_type: "number",
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
/// employed engineer, id + name).
fn engineer_refs(model: Model) -> List(Ref) {
  case model.data.people {
    Some(Ok(people)) ->
      list.map(people.people, fn(person) {
        Ref(id: person.engineer_id, name: person.name)
      })
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

fn day_rate_of(row: BoardRow) -> Float {
  case row.engagement {
    OnProject(day_rate:, ..) -> day_rate
    _ -> 0.0
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

fn format_date(date: calendar.Date) -> String {
  int.to_string(date.day)
  <> " "
  <> month_abbrev(date.month)
  <> " "
  <> int.to_string(date.year)
}

fn month_abbrev(month: calendar.Month) -> String {
  case month {
    calendar.January -> "Jan"
    calendar.February -> "Feb"
    calendar.March -> "Mar"
    calendar.April -> "Apr"
    calendar.May -> "May"
    calendar.June -> "Jun"
    calendar.July -> "Jul"
    calendar.August -> "Aug"
    calendar.September -> "Sep"
    calendar.October -> "Oct"
    calendar.November -> "Nov"
    calendar.December -> "Dec"
  }
}
