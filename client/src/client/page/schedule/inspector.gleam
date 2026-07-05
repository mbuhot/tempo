//// The Schedule page's project inspector: the selected project's run-window
//// editor, the team roster with fraction/roll-off drafting, open-seat candidate
//// nomination, drafted-change chips, and the capability coverage bars.

import client/page/schedule/scenario.{
  type CandidateState, type Inspector, type Model, type Msg, type OpenPicker,
  CandidatePicked, CandidatesFailed, CandidatesLoaded, CandidatesLoading,
  DraftRemoved, FractionChanged, Inspector, NominateOpened, PickerClosed,
  RollOffDrafted, RunDateEdited, RunFrom, RunTo,
}
import client/page/schedule/timeline
import client/time
import client/ui/atoms
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/access as perm
import shared/allocation/command as allocation_command
import shared/command.{type Command}
import shared/schedule/view as schedule_view

// --- Inspector ------------------------------------------------------------

pub fn view_inspector(
  model: Model,
  weeks: List(Date),
  projects: List(schedule_view.ProjectSchedule),
  permissions: Set(String),
) -> Element(Msg) {
  case model.selected, model.inspector {
    Some(project_id), Some(inspector) ->
      case
        list.find(projects, fn(project) { project.project_id == project_id })
      {
        Ok(project) ->
          view_inspector_panel(model, weeks, project, inspector, permissions)
        Error(Nil) -> element.none()
      }
    _, _ -> element.none()
  }
}

fn view_inspector_panel(
  model: Model,
  weeks: List(Date),
  project: schedule_view.ProjectSchedule,
  inspector: Inspector,
  permissions: Set(String),
) -> Element(Msg) {
  html.aside(
    [
      attribute.class("schedule-inspector"),
      attribute.attribute("role", "complementary"),
      attribute.attribute("aria-label", "Inspector"),
    ],
    [
      html.div([attribute.class("schedule-inspector__header")], [
        html.span([attribute.class("schedule-inspector__title")], [
          html.text(project.title),
        ]),
        html.span([attribute.class("schedule-inspector__client")], [
          html.text(project.client),
        ]),
        html.span([attribute.class("schedule-inspector__tag")], [
          html.text("inspecting"),
        ]),
      ]),
      view_run_row(inspector, project.annotation),
      view_team_section(model, weeks, project, permissions),
      view_capabilities_section(project.capabilities),
    ],
  )
}

fn view_run_row(
  inspector: Inspector,
  annotation: Option(String),
) -> Element(Msg) {
  html.div([attribute.class("schedule-inspector__run")], [
    html.div([attribute.class("schedule-inspector__dates")], [
      html.input([
        attribute.type_("date"),
        attribute.attribute("aria-label", "Run start"),
        attribute.value(inspector.run_from),
        event.on_input(fn(value) { RunDateEdited(which: RunFrom, value:) }),
      ]),
      html.span([attribute.class("schedule-inspector__arrow")], [
        html.text("→"),
      ]),
      html.input([
        attribute.type_("date"),
        attribute.attribute("aria-label", "Run end"),
        attribute.value(inspector.run_to),
        event.on_input(fn(value) { RunDateEdited(which: RunTo, value:) }),
      ]),
    ]),
    view_inspector_annotation(annotation),
  ])
}

fn view_inspector_annotation(annotation: Option(String)) -> Element(Msg) {
  case annotation {
    Some(detail) ->
      html.div([attribute.class("schedule-inspector__error")], [
        html.text(detail),
      ])
    None -> element.none()
  }
}

/// One inspector team roster row: an allocated engineer, their level and fraction.
pub type TeamRow {
  TeamRow(engineer_id: Int, name: String, level: Int, fraction: Float)
}

/// One row per engineer lane on the project, fraction from the lane's cells at `as_of`.
pub fn team_rows(
  weeks: List(Date),
  project: schedule_view.ProjectSchedule,
  as_of: Date,
) -> List(TeamRow) {
  list.map(project.lanes, fn(lane) {
    TeamRow(
      engineer_id: lane.engineer_id,
      name: lane.name,
      level: lane.level,
      fraction: current_fraction(weeks, lane, as_of),
    )
  })
}

fn current_fraction(
  weeks: List(Date),
  lane: schedule_view.EngineerLane,
  as_of: Date,
) -> Float {
  let upcoming =
    list.zip(weeks, lane.cells)
    |> list.filter(fn(pair) {
      time.date_to_day_index(pair.0) >= time.date_to_day_index(as_of)
    })
    |> list.find_map(fn(pair) { working_fraction(pair.1) })
  case upcoming {
    Ok(fraction) -> fraction
    Error(Nil) -> max_working_fraction(lane.cells)
  }
}

fn working_fraction(cell: schedule_view.CellState) -> Result(Float, Nil) {
  case cell {
    schedule_view.Working(fraction:, ..) -> Ok(fraction)
    _ -> Error(Nil)
  }
}

fn max_working_fraction(cells: List(schedule_view.CellState)) -> Float {
  cells
  |> list.filter_map(working_fraction)
  |> list.fold(0.0, float.max)
}

fn view_team_section(
  model: Model,
  weeks: List(Date),
  project: schedule_view.ProjectSchedule,
  permissions: Set(String),
) -> Element(Msg) {
  html.div([attribute.class("schedule-seats")], [
    html.div([attribute.class("schedule-seats__title")], [html.text("Team")]),
    element.fragment(
      team_rows(weeks, project, model.as_of)
      |> list.map(fn(row) { view_team_row(permissions, row) }),
    ),
    element.fragment(
      project.team
      |> list.index_map(fn(seat, index) { #(index, seat) })
      |> list.map(fn(pair) { view_seat(model, permissions, pair.0, pair.1) }),
    ),
    view_drafted_seats(model, project.project_id),
    view_drafted_team_ops(model, project.project_id, project.lanes),
  ])
}

fn view_team_row(permissions: Set(String), row: TeamRow) -> Element(Msg) {
  html.div([attribute.class("schedule-seat schedule-seat--filled")], [
    atoms.avatar(
      name: row.name,
      category: row.engineer_id,
      class: "avatar avatar--chip",
    ),
    html.span([attribute.class("schedule-seat__level")], [
      html.text("L" <> int.to_string(row.level)),
    ]),
    html.span([attribute.class("schedule-seat__name")], [html.text(row.name)]),
    view_team_fraction(permissions, row.engineer_id, row.name, row.fraction),
    view_roll_off_button(permissions, row.engineer_id),
  ])
}

fn view_team_fraction(
  permissions: Set(String),
  engineer_id: Int,
  name: String,
  fraction: Float,
) -> Element(Msg) {
  case set.contains(permissions, perm.allocation_manage) {
    False ->
      html.span([attribute.class("schedule-seat__fraction")], [
        html.text(pct(fraction)),
      ])
    True ->
      html.input([
        attribute.class("schedule-seat__fraction-input"),
        attribute.type_("number"),
        attribute.attribute("min", "0"),
        attribute.attribute("max", "1"),
        attribute.attribute("step", "0.05"),
        attribute.attribute("aria-label", "Allocation fraction for " <> name),
        attribute.value(fraction_input_text(fraction)),
        event.on_change(fn(value) { FractionChanged(engineer_id:, value:) }),
      ])
  }
}

fn fraction_input_text(value: Float) -> String {
  float.to_string(float.to_precision(value, 2))
}

fn view_roll_off_button(
  permissions: Set(String),
  engineer_id: Int,
) -> Element(Msg) {
  case set.contains(permissions, perm.allocation_manage) {
    False -> element.none()
    True ->
      html.button(
        [
          attribute.class("btn btn--ghost btn--sm schedule-seat__action"),
          event.on_click(RollOffDrafted(engineer_id:)),
        ],
        [html.text("Roll off")],
      )
  }
}

fn view_seat(
  model: Model,
  permissions: Set(String),
  index: Int,
  seat: schedule_view.Seat,
) -> Element(Msg) {
  case seat {
    schedule_view.FilledSeat(..) -> element.none()
    schedule_view.OpenSeat(level:, fraction:) ->
      html.div([attribute.class("schedule-seat schedule-seat--open")], [
        html.span([attribute.class("schedule-seat__level")], [
          html.text("L" <> int.to_string(level)),
        ]),
        html.span([attribute.class("schedule-seat__fraction")], [
          html.text(pct(fraction) <> " open"),
        ]),
        view_nominate_button(permissions, index, level, fraction),
        view_picker(model, index),
      ])
  }
}

fn view_nominate_button(
  permissions: Set(String),
  index: Int,
  level: Int,
  fraction: Float,
) -> Element(Msg) {
  case set.contains(permissions, perm.allocation_manage) {
    False -> element.none()
    True ->
      html.button(
        [
          attribute.class("btn btn--ghost btn--sm schedule-seat__action"),
          event.on_click(NominateOpened(index:, level:, fraction:)),
        ],
        [html.text("Nominate")],
      )
  }
}

fn view_picker(model: Model, index: Int) -> Element(Msg) {
  case model.inspector {
    Some(Inspector(picker: Some(picker), ..)) if picker.seat_index == index ->
      view_candidates(picker)
    _ -> element.none()
  }
}

fn view_candidates(picker: OpenPicker) -> Element(Msg) {
  html.div([attribute.class("schedule-candidates")], [
    view_candidate_list(picker.candidates),
    html.button(
      [
        attribute.class("btn btn--ghost btn--sm"),
        event.on_click(PickerClosed),
      ],
      [html.text("Cancel")],
    ),
  ])
}

fn view_candidate_list(state: CandidateState) -> Element(Msg) {
  case state {
    CandidatesLoading ->
      html.div([attribute.class("schedule-candidates__status")], [
        html.text("Loading candidates…"),
      ])
    CandidatesFailed(detail:) ->
      html.div([attribute.class("schedule-candidates__status")], [
        html.text(detail),
      ])
    CandidatesLoaded(candidates) ->
      html.div(
        [attribute.class("schedule-candidates__list")],
        list.map(candidates, view_candidate),
      )
  }
}

fn view_candidate(candidate: schedule_view.Candidate) -> Element(Msg) {
  let warn = case candidate.free == 0.0 {
    True -> [
      html.span([attribute.class("schedule-candidates__warn")], [
        html.text("▲"),
      ]),
    ]
    False -> []
  }
  html.button(
    [
      attribute.class("schedule-candidates__candidate"),
      event.on_click(CandidatePicked(candidate:)),
    ],
    list.append(
      [
        html.span([attribute.class("schedule-candidates__name")], [
          html.text(candidate.name),
        ]),
        html.span([attribute.class("schedule-candidates__level")], [
          html.text("L" <> int.to_string(candidate.level)),
        ]),
        html.span([attribute.class("schedule-candidates__proficiency")], [
          html.text(timeline.format_one_decimal(candidate.proficiency)),
        ]),
        html.span([attribute.class("schedule-candidates__free")], [
          html.text(pct(candidate.free) <> " free"),
        ]),
      ],
      warn,
    ),
  )
}

fn view_drafted_seats(model: Model, project_id: Int) -> Element(Msg) {
  case model.preview_on {
    False -> element.none()
    True ->
      element.fragment(
        model.scenario
        |> list.index_map(fn(draft, index) { #(index, draft) })
        |> list.filter_map(fn(pair) { drafted_seat_for(pair, project_id) })
        |> list.map(fn(pair) { view_drafted_seat(pair.0, pair.1) }),
      )
  }
}

fn drafted_seat_for(
  pair: #(Int, Command),
  project_id: Int,
) -> Result(#(Int, Float), Nil) {
  case pair.1 {
    command.AllocationCommand(allocation_command.AssignToProject(
      project_id: assigned_project,
      fraction:,
      ..,
    ))
      if assigned_project == project_id
    -> Ok(#(pair.0, fraction))
    _ -> Error(Nil)
  }
}

fn view_drafted_seat(index: Int, fraction: Float) -> Element(Msg) {
  html.div([attribute.class("schedule-seat schedule-seat--draft")], [
    html.span([attribute.class("schedule-seat__fraction")], [
      html.text(pct(fraction) <> " drafted"),
    ]),
    html.button(
      [
        attribute.class("schedule-seat__remove"),
        event.on_click(DraftRemoved(index:)),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_drafted_team_ops(
  model: Model,
  project_id: Int,
  lanes: List(schedule_view.EngineerLane),
) -> Element(Msg) {
  case model.preview_on {
    False -> element.none()
    True ->
      element.fragment(
        model.scenario
        |> list.index_map(fn(draft, index) { #(index, draft) })
        |> list.filter_map(fn(pair) {
          drafted_team_op_for(pair, project_id, lanes)
        })
        |> list.map(fn(pair) { view_drafted_team_op(pair.0, pair.1) }),
      )
  }
}

fn drafted_team_op_for(
  pair: #(Int, Command),
  project_id: Int,
  lanes: List(schedule_view.EngineerLane),
) -> Result(#(Int, String), Nil) {
  case pair.1 {
    command.AllocationCommand(allocation_command.RollOff(
      project_id: draft_project,
      engineer_id:,
      ..,
    ))
      if draft_project == project_id
    -> Ok(#(pair.0, "Roll off " <> lane_name(lanes, engineer_id)))
    command.AllocationCommand(allocation_command.ChangeAllocationFraction(
      project_id: draft_project,
      engineer_id:,
      fraction:,
      ..,
    ))
      if draft_project == project_id
    -> Ok(#(pair.0, pct(fraction) <> " for " <> lane_name(lanes, engineer_id)))
    _ -> Error(Nil)
  }
}

fn lane_name(
  lanes: List(schedule_view.EngineerLane),
  engineer_id: Int,
) -> String {
  lanes
  |> list.find(fn(lane) { lane.engineer_id == engineer_id })
  |> result.map(fn(lane) { lane.name })
  |> result.unwrap("")
}

fn view_drafted_team_op(index: Int, label: String) -> Element(Msg) {
  html.div([attribute.class("schedule-seat schedule-seat--draft")], [
    html.span([attribute.class("schedule-seat__fraction")], [
      html.text(label <> " drafted"),
    ]),
    html.button(
      [
        attribute.class("schedule-seat__remove"),
        event.on_click(DraftRemoved(index:)),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_capabilities_section(
  capabilities: List(schedule_view.CapabilityCoverage),
) -> Element(Msg) {
  html.div([attribute.class("schedule-caps")], [
    html.div([attribute.class("schedule-caps__title")], [
      html.text("Capabilities"),
    ]),
    element.fragment(list.map(capabilities, view_capability_bar)),
  ])
}

fn view_capability_bar(
  coverage: schedule_view.CapabilityCoverage,
) -> Element(Msg) {
  let schedule_view.CapabilityCoverage(
    name:,
    target_level:,
    team_proficiency:,
    ..,
  ) = coverage
  let fill_class = case team_proficiency >=. int.to_float(target_level) {
    True -> "schedule-caps__fill schedule-caps__fill--ok"
    False -> "schedule-caps__fill schedule-caps__fill--danger"
  }
  html.div([attribute.class("schedule-caps__row")], [
    html.div([attribute.class("schedule-caps__label")], [
      html.text(name <> " @L" <> int.to_string(target_level)),
    ]),
    html.div([attribute.class("schedule-caps__bar")], [
      html.div(
        [
          attribute.class(fill_class),
          attribute.style("width", pct_of_seven(team_proficiency)),
        ],
        [],
      ),
      html.div(
        [
          attribute.class("schedule-caps__tick"),
          attribute.style("left", pct_of_seven(int.to_float(target_level))),
        ],
        [],
      ),
    ]),
  ])
}

fn pct_of_seven(value: Float) -> String {
  timeline.format_one_decimal(float.clamp(
    value /. 7.0 *. 100.0,
    min: 0.0,
    max: 100.0,
  ))
  <> "%"
}

fn pct(fraction: Float) -> String {
  int.to_string(float.round(fraction *. 100.0)) <> "%"
}
