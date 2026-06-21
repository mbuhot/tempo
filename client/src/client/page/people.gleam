//// The People page (FR-PE*): the roster as of the global rail date (list) and a
//// single engineer's detail (deep link /people/:id) hosting the timesheet grid.
////
//// The model is a list-vs-detail sum. The list reads `GET /api/people?as_of=`;
//// the detail reads `GET /api/engineers/:id?as_of=` for the bundle AND
//// `GET /api/timesheet?engineer=<id>&week=<week-start>` for the editable grid.
//// Clicking a roster row raises `Navigate(route.People(Some(id)))`; the shell
//// owns the URL.
////
//// Contextual writes: OnboardEngineer (list), and on the detail Promote,
//// TakeLeave, RollOff, TerminateEmployment, LogWeek, and
//// Update{Contact,Banking,Emergency}Details. An open op drives a shared
//// `ui.OpForm`; submitting posts via `api.submit_operation` and, on success,
//// raises `OperationCommitted` and refetches the active sub-view. `LogWeek` is
//// assembled directly from the grid's edited cells rather than the empty-entry
//// `build_command` form.
////
//// Each fetch-result message carries the `as_of` it answers; `update` drops a
//// result whose `as_of` no longer matches the model's so a stale response never
//// clobbers a fresh view or a half-typed op form (stale-while-revalidate).

import client/api
import client/route
import client/time
import client/ui
import gleam/dict.{type Dict}
import gleam/float
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
import shared/codecs
import shared/types.{
  type EngineerDetail, type PeopleList, type PersonRow, type TimesheetCell,
  type TimesheetEntry, type TimesheetWeek, type TimesheetWeekRow, AllocationRow,
  Employment, EngineerBanking, EngineerContact, EngineerDetail,
  EngineerEmergency, LeaveBalance, LogWeek, PeopleList, PersonRow, RosterOnLeave,
  RosterOnProjects, RosterUnassigned, TimesheetCell, TimesheetEntry,
  TimesheetWeekRow,
}

// --- Model ------------------------------------------------------------------

/// The People page is either showing the roster list or one engineer's detail.
/// Each sub-view carries the `as_of` its data answers so a stale fetch is
/// dropped, the signed-in `actor` (the shell only passes it to init/refetch, so
/// the page stashes it for the writes raised in `update`), plus an optional open
/// contextual operation that survives a refetch.
pub type Model {
  ListView(
    as_of: calendar.Date,
    actor: String,
    data: ListData,
    op: Option(OpState),
  )
  DetailView(
    as_of: calendar.Date,
    actor: String,
    engineer_id: Int,
    detail: DetailData,
    timesheet: TimesheetData,
    op: Option(OpState),
  )
}

/// The roster list's load state.
pub type ListData {
  ListLoading
  ListLoaded(people: List(PersonRow))
  ListFailed(message: String)
}

/// The engineer bundle's load state. The bundle and the timesheet are fetched in
/// parallel and tracked as sibling fields on `DetailView`, so whichever arrives
/// first never discards the other.
pub type DetailData {
  DetailLoading
  DetailLoaded(detail: EngineerDetail)
  DetailFailed(message: String)
}

/// The weekly timesheet grid's load state. When loaded it carries the fetched
/// week plus the presenter's in-progress edits keyed by `#(project_id,
/// day_index)`, so typed hours survive a re-render and feed the `LogWeek` submit.
pub type TimesheetData {
  TimesheetLoading
  TimesheetLoaded(week: TimesheetWeek, edits: Dict(#(Int, Int), String))
  TimesheetFailed(message: String)
}

/// An open contextual operation: its kind, the form being filled, and the most
/// recent rejection prompt (an invalid field or a server refusal) to surface.
pub type OpState {
  OpState(kind: ui.OpKind, form: ui.OpForm, error: Option(String))
}

// --- Messages ---------------------------------------------------------------

/// The page's messages, wrapped by the shell as `PeopleMsg(people.Msg)`. Fetch
/// results carry the `as_of` they answer (and the timesheet its engineer id) so
/// `update` can drop a stale response.
pub type Msg {
  RosterFetched(
    as_of: calendar.Date,
    result: Result(PeopleList, rsvp.Error(String)),
  )
  DetailFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(EngineerDetail, rsvp.Error(String)),
  )
  TimesheetFetched(
    as_of: calendar.Date,
    engineer_id: Int,
    result: Result(TimesheetWeek, rsvp.Error(String)),
  )
  RowClicked(engineer_id: Int)
  BackClicked
  OpOpened(kind: ui.OpKind)
  OpCancelled
  OpFieldEdited(field: ui.OpField, value: String)
  OpSubmitted
  CellEdited(project_id: Int, day: calendar.Date, value: String)
  TimesheetSubmitted
  OperationReturned(result: Result(List(types.Event), rsvp.Error(String)))
}

/// The cross-page effects a page can raise (the ONLY shell coupling, frozen in
/// step 5): navigate to a route, or signal a write committed (so the shell can
/// refresh as needed). Identical across all 7 pages.
pub type OutMsg {
  Navigate(route.Route)
  OperationCommitted
}

// --- Init / refetch ---------------------------------------------------------

/// Build the page's initial state for `route` at `as_of` on the signed-in
/// `actor`'s behalf. `People(Some(id))` opens that engineer's detail (so a cold
/// deep link to `/people/:id` lands on the detail); any other route opens the
/// roster list.
pub fn init(
  route: route.Route,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case route {
    route.People(id: Some(engineer_id)) -> #(
      DetailView(
        as_of:,
        actor:,
        engineer_id:,
        detail: DetailLoading,
        timesheet: TimesheetLoading,
        op: None,
      ),
      fetch_detail(as_of, engineer_id),
    )
    _ -> #(
      ListView(as_of:, actor:, data: ListLoading, op: None),
      fetch_roster(as_of),
    )
  }
}

/// Re-fetch the active sub-view for a new `as_of` without dropping any open op
/// form (stale-while-revalidate). The list refetches the roster; the detail
/// refetches both the bundle and the timesheet for the new instant.
pub fn refetch(
  model: Model,
  as_of: calendar.Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  case model {
    ListView(op:, ..) -> #(
      ListView(as_of:, actor:, data: ListLoading, op:),
      fetch_roster(as_of),
    )
    DetailView(engineer_id:, op:, ..) -> #(
      DetailView(
        as_of:,
        actor:,
        engineer_id:,
        detail: DetailLoading,
        timesheet: TimesheetLoading,
        op:,
      ),
      fetch_detail(as_of, engineer_id),
    )
  }
}

// --- Fetches ----------------------------------------------------------------

fn fetch_roster(as_of: calendar.Date) -> Effect(Msg) {
  api.get(
    "/api/people?as_of=" <> time.iso_date(as_of),
    codecs.people_list_decoder(),
    fn(result) { RosterFetched(as_of:, result:) },
  )
}

fn fetch_detail(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  effect.batch([
    api.get(
      "/api/engineers/"
        <> int.to_string(engineer_id)
        <> "?as_of="
        <> time.iso_date(as_of),
      codecs.engineer_detail_decoder(),
      fn(result) { DetailFetched(as_of:, engineer_id:, result:) },
    ),
    fetch_timesheet(as_of, engineer_id),
  ])
}

fn fetch_timesheet(as_of: calendar.Date, engineer_id: Int) -> Effect(Msg) {
  let week = time.week_start_of(as_of)
  api.get(
    "/api/timesheet?engineer="
      <> int.to_string(engineer_id)
      <> "&week="
      <> time.iso_date(week),
    codecs.timesheet_week_decoder(),
    fn(result) { TimesheetFetched(as_of:, engineer_id:, result:) },
  )
}

// --- Update -----------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    RosterFetched(as_of:, result:) ->
      case model {
        ListView(as_of: current, actor:, op:, ..) if current == as_of ->
          case result {
            Ok(PeopleList(people:, ..)) -> #(
              ListView(as_of:, actor:, data: ListLoaded(people:), op:),
              effect.none(),
              [],
            )
            Error(error) -> #(
              ListView(
                as_of:,
                actor:,
                data: ListFailed(api.describe_error(error)),
                op:,
              ),
              effect.none(),
              [],
            )
          }
        _ -> #(model, effect.none(), [])
      }

    DetailFetched(as_of:, engineer_id:, result:) ->
      case model {
        DetailView(
          as_of: current,
          actor:,
          engineer_id: shown,
          timesheet:,
          op:,
          ..,
        )
          if current == as_of && shown == engineer_id
        -> {
          let detail = case result {
            Ok(detail) -> DetailLoaded(detail:)
            Error(error) -> DetailFailed(api.describe_error(error))
          }
          #(
            DetailView(as_of:, actor:, engineer_id:, detail:, timesheet:, op:),
            effect.none(),
            [],
          )
        }
        _ -> #(model, effect.none(), [])
      }

    TimesheetFetched(as_of:, engineer_id:, result:) ->
      case model {
        DetailView(as_of: current, actor:, engineer_id: shown, detail:, op:, ..)
          if current == as_of && shown == engineer_id
        -> {
          let timesheet = case result {
            Ok(week) -> TimesheetLoaded(week:, edits: dict.new())
            Error(error) -> TimesheetFailed(api.describe_error(error))
          }
          #(
            DetailView(as_of:, actor:, engineer_id:, detail:, timesheet:, op:),
            effect.none(),
            [],
          )
        }
        _ -> #(model, effect.none(), [])
      }

    RowClicked(engineer_id:) -> #(model, effect.none(), [
      Navigate(route.People(id: Some(engineer_id))),
    ])

    BackClicked -> #(model, effect.none(), [Navigate(route.People(id: None))])

    OpOpened(kind:) -> #(
      set_op(
        model,
        Some(OpState(kind:, form: blank_form(model, kind), error: None)),
      ),
      effect.none(),
      [],
    )

    OpCancelled -> #(set_op(model, None), effect.none(), [])

    OpFieldEdited(field:, value:) ->
      case current_op(model) {
        Some(OpState(kind:, form:, ..)) -> #(
          set_op(
            model,
            Some(OpState(
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
      case current_op(model) {
        Some(OpState(kind:, form:, ..)) ->
          case ui.build_command(kind, form) {
            Ok(command) -> #(
              model,
              api.submit_operation(actor_of(model), command, OperationReturned),
              [],
            )
            Error(prompt) -> #(
              set_op(model, Some(OpState(kind:, form:, error: Some(prompt)))),
              effect.none(),
              [],
            )
          }
        None -> #(model, effect.none(), [])
      }

    CellEdited(project_id:, day:, value:) -> #(
      edit_cell(model, project_id, day, value),
      effect.none(),
      [],
    )

    TimesheetSubmitted ->
      case model {
        DetailView(engineer_id:, timesheet: TimesheetLoaded(week:, edits:), ..) -> #(
          model,
          api.submit_operation(
            actor_of(model),
            LogWeek(engineer_id:, entries: week_entries(week, edits)),
            OperationReturned,
          ),
          [],
        )
        _ -> #(model, effect.none(), [])
      }

    OperationReturned(result:) ->
      case result {
        Ok(_events) -> {
          let #(refreshed, fetch) = refetch_active(set_op(model, None))
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

// --- Update helpers ---------------------------------------------------------

/// The open contextual operation, regardless of sub-view.
fn current_op(model: Model) -> Option(OpState) {
  case model {
    ListView(op:, ..) -> op
    DetailView(op:, ..) -> op
  }
}

/// Set (or clear) the open contextual operation, preserving the sub-view.
fn set_op(model: Model, op: Option(OpState)) -> Model {
  case model {
    ListView(as_of:, actor:, data:, ..) -> ListView(as_of:, actor:, data:, op:)
    DetailView(as_of:, actor:, engineer_id:, detail:, timesheet:, ..) ->
      DetailView(as_of:, actor:, engineer_id:, detail:, timesheet:, op:)
  }
}

/// Surface a rejection on the open op form, leaving its typed fields intact.
fn set_op_error(model: Model, message: String) -> Model {
  case current_op(model) {
    Some(OpState(kind:, form:, ..)) ->
      set_op(model, Some(OpState(kind:, form:, error: Some(message))))
    None -> model
  }
}

/// A fresh op form seeded with the visible engineer's id where relevant (every
/// detail op acts on the shown engineer), defaulting dates to the sub-view's
/// as-of.
fn blank_form(model: Model, kind: ui.OpKind) -> ui.OpForm {
  let form = ui.blank_op_form(kind, as_of_of(model))
  case model {
    DetailView(engineer_id:, ..) ->
      ui.update_op_form(form, ui.FEngineerId, int.to_string(engineer_id))
    ListView(..) -> form
  }
}

/// Record a typed timesheet cell value, keyed by `#(project_id, day_index)`, so
/// the grid re-renders the typed value and the submit reads it back.
fn edit_cell(
  model: Model,
  project_id: Int,
  day: calendar.Date,
  value: String,
) -> Model {
  case model {
    DetailView(
      as_of:,
      actor:,
      engineer_id:,
      detail:,
      timesheet: TimesheetLoaded(week:, edits:),
      op:,
    ) -> {
      let key = #(project_id, time.date_to_day_index(day))
      let edits = dict.insert(edits, key, value)
      DetailView(
        as_of:,
        actor:,
        engineer_id:,
        detail:,
        timesheet: TimesheetLoaded(week:, edits:),
        op:,
      )
    }
    _ -> model
  }
}

/// Assemble the `LogWeek` entries from the fetched grid and the presenter's
/// edits: one entry per editable (project, day) cell, taking the typed value
/// when present (an unparseable or blank typed value clears the cell at 0.0) and
/// otherwise the cell's already-logged hours. Disabled cells are never logged.
fn week_entries(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> List(TimesheetEntry) {
  list.flat_map(week.rows, fn(row) {
    let TimesheetWeekRow(project_id:, cells:, ..) = row
    list.filter_map(cells, fn(cell) {
      let TimesheetCell(date:, allocated:, hours:) = cell
      case allocated {
        False -> Error(Nil)
        True -> {
          let key = #(project_id, time.date_to_day_index(date))
          let value = case dict.get(edits, key) {
            Ok(typed) -> parse_hours(typed)
            Error(Nil) -> hours
          }
          Ok(TimesheetEntry(project_id:, day: date, hours: value))
        }
      }
    })
  })
}

/// Parse a typed hours cell; a blank or unparseable value clears the cell (0.0).
/// Accepts both decimals ("7.5") and bare integers ("8").
fn parse_hours(raw: String) -> Float {
  let trimmed = string.trim(raw)
  case float.parse(trimmed) {
    Ok(value) -> value
    Error(Nil) ->
      case int.parse(trimmed) {
        Ok(value) -> int.to_float(value)
        Error(Nil) -> 0.0
      }
  }
}

/// Re-fetch the active sub-view (used after a committed write); mirrors
/// `refetch` but reads the sub-view's own as-of.
fn refetch_active(model: Model) -> #(Model, Effect(Msg)) {
  case model {
    ListView(as_of:, actor:, op:, ..) -> #(
      ListView(as_of:, actor:, data: ListLoading, op:),
      fetch_roster(as_of),
    )
    DetailView(as_of:, actor:, engineer_id:, op:, ..) -> #(
      DetailView(
        as_of:,
        actor:,
        engineer_id:,
        detail: DetailLoading,
        timesheet: TimesheetLoading,
        op:,
      ),
      fetch_detail(as_of, engineer_id),
    )
  }
}

fn as_of_of(model: Model) -> calendar.Date {
  case model {
    ListView(as_of:, ..) -> as_of
    DetailView(as_of:, ..) -> as_of
  }
}

/// The signed-in actor the page stashed at init/refetch, stamped onto every
/// write it raises in `update`.
fn actor_of(model: Model) -> String {
  case model {
    ListView(actor:, ..) -> actor
    DetailView(actor:, ..) -> actor
  }
}

// --- View -------------------------------------------------------------------

pub fn view(model: Model, as_of: calendar.Date) -> Element(Msg) {
  let _ = as_of
  case model {
    ListView(data:, op:, ..) -> view_list(data, op, as_of_of(model))
    DetailView(detail:, timesheet:, op:, ..) ->
      view_detail(detail, timesheet, op)
  }
}

// --- List view --------------------------------------------------------------

fn view_list(
  data: ListData,
  op: Option(OpState),
  as_of: calendar.Date,
) -> Element(Msg) {
  let head =
    ui.page_head(
      title: "People",
      blurb: "Everyone employed as of "
        <> time.iso_date(as_of)
        <> ". Open a person for their full record and history.",
      actions: [op_button("+ Onboard", ui.OpOnboardEngineer, False)],
    )
  let op_panel = view_op_panel(op)
  case data {
    ListLoading -> column([head, op_panel, ui.empty_state("Loading roster…")])
    ListFailed(message:) ->
      column([
        head,
        op_panel,
        ui.empty_state("Could not load the roster: " <> message),
      ])
    ListLoaded(people:) -> column([head, op_panel, roster_panel(people)])
  }
}

fn roster_panel(people: List(PersonRow)) -> Element(Msg) {
  let rows = list.map(people, roster_row)
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

fn roster_row(person: PersonRow) -> Element(Msg) {
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
  html.tr(
    [attribute.class("clickable"), event.on_click(RowClicked(engineer_id))],
    [
      html.td([], [name_cell(engineer_id, name, email)]),
      html.td([], [
        html.span([attribute.class("level-pill")], [
          html.text(ui.level_band(level)),
        ]),
      ]),
      html.td([], [ui.pill(variant:, label:)]),
      html.td([attribute.class("num")], [html.text(allocated)]),
      html.td([attribute.class("num")], [html.text(ui.days(annual_balance))]),
      html.td([attribute.class("num")], [html.text(ui.money(day_rate))]),
    ],
  )
}

fn name_cell(engineer_id: Int, name: String, email: String) -> Element(Msg) {
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
fn status_pill(status: types.RosterStatus) -> #(String, String) {
  case status {
    RosterOnProjects(projects:) -> #("active", join_titles(projects))
    RosterOnLeave(kind:) -> #("issued", "On " <> kind <> " leave")
    RosterUnassigned -> #("ended", "Unassigned")
  }
}

fn join_titles(titles: List(String)) -> String {
  case titles {
    [] -> "On projects"
    _ -> string_join(titles, ", ")
  }
}

// --- Detail view ------------------------------------------------------------

fn view_detail(
  detail: DetailData,
  timesheet: TimesheetData,
  op: Option(OpState),
) -> Element(Msg) {
  let back =
    html.a([attribute.class("back-link"), event.on_click(BackClicked)], [
      html.text("‹ All engineers"),
    ])
  case detail {
    DetailLoading -> column([back, ui.empty_state("Loading engineer…")])
    DetailFailed(message:) ->
      column([back, ui.empty_state("Could not load this engineer: " <> message)])
    DetailLoaded(detail:) ->
      column([
        back,
        detail_head(detail),
        view_op_panel(op),
        detail_grid(detail, timesheet),
      ])
  }
}

fn detail_head(detail: EngineerDetail) -> Element(Msg) {
  let EngineerDetail(engineer_id:, name:, level:, allocations:, ..) = detail
  html.div([attribute.class("page-head")], [
    html.div([], [
      html.h1([attribute.class("detail__title")], [
        ui.avatar(name:, category: engineer_id, class: "avatar"),
        html.text(name),
      ]),
      html.div([attribute.class("detail__subtitle")], [
        html.text(ui.level_band(level)),
      ]),
      html.p([], [html.text(situation(allocations))]),
    ]),
    html.div([attribute.class("action-row")], [
      op_button("Take leave", ui.OpTakeLeave, True),
      op_button("Roll off", ui.OpRollOff, True),
      op_button("Terminate", ui.OpTerminateEmployment, True),
      op_button("Promote", ui.OpPromote, False),
    ]),
  ])
}

/// A one-line situation for the detail header: allocated to the active
/// project(s) or currently unassigned, derived from the allocations the server
/// already flagged `active` for the detail's as-of. The bundle carries no leave
/// active-flag, so leave is reflected only on the roster list.
fn situation(allocations: List(types.AllocationRow)) -> String {
  let active_projects =
    list.filter_map(allocations, fn(allocation) {
      case allocation {
        AllocationRow(project:, active: True, ..) -> Ok(project)
        _ -> Error(Nil)
      }
    })
  case active_projects {
    [] -> "Currently unassigned."
    titles -> "Allocated to " <> string_join(titles, " & ") <> "."
  }
}

fn detail_grid(
  detail: EngineerDetail,
  timesheet: TimesheetData,
) -> Element(Msg) {
  html.div([attribute.class("detail-grid")], [
    html.div([], [
      allocations_panel(detail.allocations),
      timesheet_panel(timesheet),
    ]),
    html.div([], [
      balance_panel(detail.balance),
      contact_panel(detail.contact),
      banking_panel(detail.banking),
      employment_panel(detail.employment, detail.level, detail.emergency),
    ]),
  ])
}

fn allocations_panel(allocations: List(types.AllocationRow)) -> Element(Msg) {
  let rows = list.map(allocations, allocation_row)
  let body = case allocations {
    [] -> [ui.empty_state("No allocations on record.")]
    _ -> [
      ui.data_table(
        headers: [
          #("Project", False),
          #("Fraction", True),
          #("Period", False),
          #("State", False),
        ],
        rows:,
      ),
    ]
  }
  ui.panel(title: "Allocations", count: "", right: [], body:)
}

fn allocation_row(allocation: types.AllocationRow) -> Element(Msg) {
  let AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ) = allocation
  let #(variant, label) = case active {
    True -> #("active", "active")
    False -> #("ended", "ended")
  }
  html.tr([], [
    html.td([], [
      ui.swatch(category: project_id, inline: True),
      html.text(project),
    ]),
    html.td([attribute.class("num")], [html.text(ui.fraction(fraction))]),
    html.td([attribute.class("mono muted")], [
      html.text(time.iso_date(valid_from) <> " → " <> time.iso_date(valid_to)),
    ]),
    html.td([], [ui.pill(variant:, label:)]),
  ])
}

// --- Timesheet grid ---------------------------------------------------------

fn timesheet_panel(timesheet: TimesheetData) -> Element(Msg) {
  case timesheet {
    TimesheetLoading ->
      ui.panel(title: "Timesheet", count: "", right: [], body: [
        ui.empty_state("Loading week…"),
      ])
    TimesheetFailed(message:) ->
      ui.panel(title: "Timesheet", count: "", right: [], body: [
        ui.empty_state("Could not load the timesheet: " <> message),
      ])
    TimesheetLoaded(week:, edits:) ->
      ui.panel(
        title: "Timesheet",
        count: "week of " <> time.iso_date(week.week_start),
        right: [submit_week_button(week)],
        body: [
          html.div([attribute.class("pad-block")], [timesheet_grid(week, edits)]),
        ],
      )
  }
}

fn submit_week_button(week: TimesheetWeek) -> Element(Msg) {
  case week.rows {
    [] -> element.none()
    _ ->
      html.button(
        [attribute.class("btn btn--sm"), event.on_click(TimesheetSubmitted)],
        [html.text("Log week")],
      )
  }
}

fn timesheet_grid(
  week: TimesheetWeek,
  edits: Dict(#(Int, Int), String),
) -> Element(Msg) {
  let header =
    html.tr([], [
      html.th([], [html.text("Project")]),
      ..list.map(week.days, day_header)
    ])
  let body = case week.rows {
    [] -> [
      html.tr([], [
        html.td([attribute.attribute("colspan", "8")], [
          ui.empty_state("Nothing to log this week."),
        ]),
      ]),
    ]
    rows -> list.map(rows, fn(row) { timesheet_row(row, edits) })
  }
  html.table([attribute.class("timesheet")], [
    html.thead([], [header]),
    html.tbody([], body),
  ])
}

fn day_header(date: calendar.Date) -> Element(Msg) {
  let weekday = day_of_week(date)
  let class = case weekday >= 5 {
    True -> "timesheet__weekend"
    False -> ""
  }
  html.th([attribute.class(class)], [
    html.text(weekday_label(weekday)),
    html.br([]),
    html.span([attribute.class("timesheet__daynum")], [
      html.text(int.to_string(date.day)),
    ]),
  ])
}

fn timesheet_row(
  row: TimesheetWeekRow,
  edits: Dict(#(Int, Int), String),
) -> Element(Msg) {
  let TimesheetWeekRow(project_id:, project:, cells:) = row
  html.tr([], [
    html.td([], [
      ui.swatch(category: project_id, inline: True),
      html.text(project),
    ]),
    ..list.map(cells, fn(cell) { timesheet_cell(project_id, cell, edits) })
  ])
}

fn timesheet_cell(
  project_id: Int,
  cell: TimesheetCell,
  edits: Dict(#(Int, Int), String),
) -> Element(Msg) {
  let TimesheetCell(date:, allocated:, hours:) = cell
  let key = #(project_id, time.date_to_day_index(date))
  let value = case dict.get(edits, key) {
    Ok(typed) -> typed
    Error(Nil) -> hours_display(hours)
  }
  let #(class, disabled) = case allocated {
    True -> #("timesheet__cell", False)
    False -> #("timesheet__cell timesheet__cell--disabled", True)
  }
  html.td([attribute.class(class)], [
    html.input([
      attribute.value(value),
      attribute.disabled(disabled),
      attribute.attribute("aria-label", "Hours"),
      event.on_input(fn(value) { CellEdited(project_id:, day: date, value:) }),
    ]),
  ])
}

/// A logged-hours value for display in a grid cell: empty when zero (so an
/// unlogged cell shows blank, matching the prototype), otherwise the number.
fn hours_display(hours: Float) -> String {
  case hours == 0.0 {
    True -> ""
    False -> ui.days(hours)
  }
}

// --- Side panels ------------------------------------------------------------

fn balance_panel(balance: types.LeaveBalance) -> Element(Msg) {
  let LeaveBalance(annual:, sick:, ..) = balance
  ui.panel(title: "Leave balance", count: "", right: [], body: [
    html.div([attribute.class("pad-block")], [
      balance_bar("Annual", annual, 20.0),
      balance_bar("Sick", sick, 10.0),
    ]),
  ])
}

fn balance_bar(label: String, value: Float, max: Float) -> Element(Msg) {
  let pct = int.min(float_round(value /. max *. 100.0), 100)
  html.div([attribute.class("balance")], [
    html.div([attribute.class("balance__head")], [
      html.span([attribute.class("eyebrow")], [html.text(label)]),
      html.span([attribute.class("balance__value")], [
        html.text(ui.days(value) <> " days"),
      ]),
    ]),
    html.div([attribute.class("spark spark--lg")], [
      html.i([attribute.style("width", int.to_string(pct) <> "%")], []),
    ]),
  ])
}

fn contact_panel(contact: types.EngineerContact) -> Element(Msg) {
  let EngineerContact(name:, email:, phone:, postal_address:, ..) = contact
  let _ = name
  ui.panel(title: "Contact", count: "", right: [contact_edit_button()], body: [
    html.div([attribute.class("pad-detail")], [
      html.div([attribute.class("kv")], [
        ui.kv(key: "Email", value: email, mono: False),
        ui.kv(key: "Phone", value: phone, mono: True),
        ui.kv(key: "Address", value: postal_address, mono: False),
      ]),
    ]),
  ])
}

fn banking_panel(banking: types.EngineerBanking) -> Element(Msg) {
  let EngineerBanking(bank:, branch:, account_no:, account_name:, ..) = banking
  ui.panel(
    title: "Banking",
    count: "",
    right: [op_button("Edit", ui.OpUpdateBanking, True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          ui.kv(key: "Bank", value: bank, mono: False),
          ui.kv(key: "BSB", value: branch, mono: True),
          ui.kv(key: "Account", value: account_no, mono: True),
          ui.kv(key: "Name", value: account_name, mono: False),
        ]),
      ]),
    ],
  )
}

fn contact_edit_button() -> Element(Msg) {
  op_button("Edit", ui.OpUpdateContact, True)
}

fn employment_panel(
  employment: types.Employment,
  level: Int,
  emergency: types.EngineerEmergency,
) -> Element(Msg) {
  let Employment(started:, monthly_salary:, ..) = employment
  let EngineerEmergency(relation:, name:, phone:, ..) = emergency
  let emergency_line = name <> " (" <> relation <> ", " <> phone <> ")"
  ui.panel(
    title: "Employment",
    count: "",
    right: [op_button("Emergency", ui.OpUpdateEmergency, True)],
    body: [
      html.div([attribute.class("pad-detail")], [
        html.div([attribute.class("kv")], [
          ui.kv(key: "Started", value: time.iso_date(started), mono: True),
          ui.kv(key: "Level", value: ui.level_band(level), mono: False),
          ui.kv(
            key: "Monthly salary",
            value: ui.money(monthly_salary),
            mono: True,
          ),
          ui.kv(key: "Emergency", value: emergency_line, mono: False),
        ]),
      ]),
    ],
  )
}

// --- Op form ----------------------------------------------------------------

/// A button that opens the contextual operation `kind`. `ghost` renders the
/// secondary (outlined) variant.
fn op_button(label: String, kind: ui.OpKind, ghost: Bool) -> Element(Msg) {
  let class = case ghost {
    True -> "btn btn--ghost btn--sm"
    False -> "btn btn--sm"
  }
  html.button([attribute.class(class), event.on_click(OpOpened(kind))], [
    html.text(label),
  ])
}

/// The inline operation form panel, shown only while an op is open. Renders the
/// fields the chosen kind needs, the rejection prompt if any, and Apply/Cancel.
fn view_op_panel(op: Option(OpState)) -> Element(Msg) {
  case op {
    None -> element.none()
    Some(OpState(kind:, form:, error:)) ->
      ui.panel(title: op_title(kind), count: "", right: [], body: [
        html.div([attribute.class("pad-detail")], [
          html.div([attribute.class("op-form")], op_fields(kind, form)),
          op_error(error),
          html.div([attribute.class("op-form__actions")], [
            html.button(
              [attribute.class("btn btn--sm"), event.on_click(OpSubmitted)],
              [html.text("Apply")],
            ),
            html.button(
              [
                attribute.class("btn btn--ghost btn--sm"),
                event.on_click(OpCancelled),
              ],
              [html.text("Cancel")],
            ),
          ]),
        ]),
      ])
  }
}

fn op_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      html.div([attribute.class("op-form__error")], [html.text(message)])
  }
}

/// The form fields each operation kind reads, bound to the shared `OpForm`. Only
/// the kinds this page raises have a populated arm; any other kind shows just its
/// engineer-id field (a safe fallback the page never triggers).
fn op_fields(kind: ui.OpKind, form: ui.OpForm) -> List(Element(Msg)) {
  case kind {
    ui.OpOnboardEngineer -> [
      text_field("Name", ui.FName, form.name),
      number_field("Level", ui.FLevel, form.level),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpPromote -> [
      number_field("New level", ui.FLevel, form.level),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpTakeLeave -> [
      text_field("Kind", ui.FKind, form.kind),
      date_field("From", ui.FValidFrom, form.valid_from),
      date_field("To", ui.FValidTo, form.valid_to),
    ]
    ui.OpRollOff -> [
      number_field("Project id", ui.FProjectId, form.project_id),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpTerminateEmployment -> [
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateContact -> [
      text_field("Name", ui.FName, form.name),
      text_field("Email", ui.FEmail, form.email),
      text_field("Phone", ui.FPhone, form.phone),
      text_field("Address", ui.FPostalAddress, form.postal_address),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateBanking -> [
      text_field("Bank", ui.FBank, form.bank),
      text_field("BSB", ui.FBranch, form.branch),
      text_field("Account", ui.FAccountNo, form.account_no),
      text_field("Account name", ui.FAccountName, form.account_name),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    ui.OpUpdateEmergency -> [
      text_field("Relation", ui.FRelation, form.relation),
      text_field("Name", ui.FEmergencyName, form.emergency_name),
      text_field("Phone", ui.FEmergencyPhone, form.emergency_phone),
      text_field("Email", ui.FEmergencyEmail, form.emergency_email),
      date_field("Effective", ui.FEffective, form.effective),
    ]
    _ -> [number_field("Engineer id", ui.FEngineerId, form.engineer_id)]
  }
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

fn op_title(kind: ui.OpKind) -> String {
  case kind {
    ui.OpOnboardEngineer -> "Onboard an engineer"
    ui.OpPromote -> "Promote"
    ui.OpTakeLeave -> "Take leave"
    ui.OpRollOff -> "Roll off a project"
    ui.OpTerminateEmployment -> "Terminate employment"
    ui.OpUpdateContact -> "Update contact details"
    ui.OpUpdateBanking -> "Update banking details"
    ui.OpUpdateEmergency -> "Update emergency contact"
    _ -> "Operation"
  }
}

// --- Small helpers ----------------------------------------------------------

fn column(children: List(Element(Msg))) -> Element(Msg) {
  html.div([], children)
}

/// The Mon=0..Sun=6 weekday index of a date, via its unix-day index (unix-day 0
/// is a Thursday = index 3 in this scheme).
fn day_of_week(date: calendar.Date) -> Int {
  let index = time.date_to_day_index(date)
  int.modulo(index + 3, 7) |> result_unwrap(0)
}

fn weekday_label(weekday: Int) -> String {
  case weekday {
    0 -> "Mon"
    1 -> "Tue"
    2 -> "Wed"
    3 -> "Thu"
    4 -> "Fri"
    5 -> "Sat"
    _ -> "Sun"
  }
}

fn float_round(value: Float) -> Int {
  float.round(value)
}

fn string_join(parts: List(String), with separator: String) -> String {
  string.join(parts, separator)
}

fn result_unwrap(result: Result(Int, Nil), default: Int) -> Int {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}
