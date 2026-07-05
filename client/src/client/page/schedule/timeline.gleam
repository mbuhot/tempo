//// The Schedule page's timeline views: the portfolio stats strip and, per
//// project, the header block and the week-by-week grid of engineer lanes and
//// requirement gap rows.

import client/page/schedule/scenario.{
  type Model, type Msg, ApplyRequested, PreviewToggled, ProjectSelected,
  ScenarioDiscarded,
}
import client/time
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
import shared/schedule/view as schedule_view

// --- Stats strip -------------------------------------------------------------

pub fn view_stats(
  model: Model,
  projects: List(schedule_view.ProjectSchedule),
  permissions: Set(String),
) -> Element(Msg) {
  let short_lines = count_short_lines(projects)
  let over_allocated = count_over_allocated_engineers(projects)
  let on_leave = count_on_leave_engineers(projects)
  html.div([attribute.class("schedule-stats")], [
    html.span([attribute.class("schedule-stats__stat")], [
      html.span(
        [attribute.class("schedule-stats__dot schedule-stats__dot--gap")],
        [],
      ),
      html.text(int.to_string(short_lines) <> " requirement lines short"),
    ]),
    html.span([attribute.class("schedule-stats__stat")], [
      html.span(
        [attribute.class("schedule-stats__dot schedule-stats__dot--warn")],
        [],
      ),
      html.text(int.to_string(over_allocated) <> " over-allocated"),
    ]),
    html.span([attribute.class("schedule-stats__stat")], [
      html.span(
        [attribute.class("schedule-stats__dot schedule-stats__dot--leave")],
        [],
      ),
      html.text(int.to_string(on_leave) <> " on leave"),
    ]),
    view_stats_actions(model, permissions),
  ])
}

fn view_stats_actions(model: Model, permissions: Set(String)) -> Element(Msg) {
  case set.contains(permissions, perm.allocation_manage) {
    False -> html.div([attribute.class("schedule-stats__actions")], [])
    True ->
      html.div([attribute.class("schedule-stats__actions")], [
        html.label([attribute.class("schedule-stats__preview")], [
          html.input([
            attribute.type_("checkbox"),
            attribute.checked(model.preview_on),
            event.on_check(fn(_) { PreviewToggled }),
          ]),
          html.text("Preview"),
        ]),
        html.button(
          [
            attribute.class("btn btn--ghost btn--sm"),
            attribute.disabled(model.scenario == []),
            event.on_click(ScenarioDiscarded),
          ],
          [html.text("Discard changes")],
        ),
        html.button(
          [
            attribute.class("btn btn--sm"),
            attribute.disabled(model.scenario == [] || model.applying),
            event.on_click(ApplyRequested),
          ],
          [html.text("Apply changes")],
        ),
        view_apply_error(model.apply_error),
      ])
  }
}

fn view_apply_error(apply_error: Option(String)) -> Element(Msg) {
  case apply_error {
    Some(detail) ->
      html.span([attribute.class("schedule-stats__error")], [
        html.text(detail),
      ])
    None -> element.none()
  }
}

fn count_short_lines(projects: List(schedule_view.ProjectSchedule)) -> Int {
  projects
  |> list.flat_map(fn(project) { project.lines })
  |> list.filter(line_has_gap)
  |> list.length
}

fn count_over_allocated_engineers(
  projects: List(schedule_view.ProjectSchedule),
) -> Int {
  projects
  |> list.flat_map(fn(project) { project.lanes })
  |> list.filter(fn(lane) {
    list.any(lane.cells, fn(cell) {
      case cell {
        schedule_view.Working(_, True) -> True
        _ -> False
      }
    })
  })
  |> list.map(fn(lane) { lane.engineer_id })
  |> list.unique
  |> list.length
}

fn count_on_leave_engineers(
  projects: List(schedule_view.ProjectSchedule),
) -> Int {
  projects
  |> list.flat_map(fn(project) { project.lanes })
  |> list.filter(fn(lane) {
    list.any(lane.cells, fn(cell) {
      case cell {
        schedule_view.OnLeave -> True
        _ -> False
      }
    })
  })
  |> list.map(fn(lane) { lane.engineer_id })
  |> list.unique
  |> list.length
}

// --- Project block ------------------------------------------------------------

pub fn view_project(
  model: Model,
  weeks: List(Date),
  project: schedule_view.ProjectSchedule,
) -> Element(Msg) {
  let schedule_view.ProjectSchedule(
    project_id:,
    title:,
    client:,
    run_from:,
    run_to:,
    lanes:,
    lines:,
    annotation:,
    ..,
  ) = project
  let selected = model.selected == Some(project_id)
  let class = case selected {
    True -> "schedule-project schedule-project--selected"
    False -> "schedule-project"
  }
  html.section([attribute.class(class), attribute.aria_label(title)], [
    html.div(
      [
        attribute.class("schedule-project__header"),
        attribute.role("button"),
        event.on_click(ProjectSelected(project_id:)),
      ],
      [
        html.span([attribute.class("schedule-project__title")], [
          html.text(title),
        ]),
        html.span([attribute.class("schedule-project__client")], [
          html.text(client),
        ]),
        html.span([attribute.class("schedule-project__run")], [
          html.text(time.iso_date(run_from) <> " → " <> time.iso_date(run_to)),
        ]),
        view_gap_chips(lines),
        view_annotation(annotation),
      ],
    ),
    view_grid(weeks, lanes, lines),
  ])
}

fn view_gap_chips(lines: List(schedule_view.RequirementLine)) -> Element(Msg) {
  html.div(
    [attribute.class("schedule-project__reqs")],
    lines
      |> list.filter(line_has_gap)
      |> list.map(fn(line) {
        html.span([attribute.class("schedule-req")], [
          html.text(line_label(line.kind)),
        ])
      }),
  )
}

fn view_annotation(annotation: Option(String)) -> Element(Msg) {
  case annotation {
    Some(detail) ->
      html.span([attribute.class("schedule-project__annotation")], [
        html.text(detail),
      ])
    None -> element.none()
  }
}

fn line_has_gap(line: schedule_view.RequirementLine) -> Bool {
  list.any(line.gaps, fn(gap) { gap >. 0.0 })
}

fn line_label(kind: schedule_view.LineKind) -> String {
  case kind {
    schedule_view.LevelLine(level:) -> "L" <> int.to_string(level)
    schedule_view.CapabilityLine(name:, target_level:, ..) ->
      name <> " @L" <> int.to_string(target_level)
  }
}

// --- Grid ---------------------------------------------------------------------

fn view_grid(
  weeks: List(Date),
  lanes: List(schedule_view.EngineerLane),
  lines: List(schedule_view.RequirementLine),
) -> Element(Msg) {
  html.div([attribute.class("schedule-grid-wrap")], [
    html.div([attribute.class("schedule-grid")], [
      view_week_header(weeks),
      html.div([], list.map(lanes, view_lane)),
      html.div([], list.map(lines, view_gap_row)),
    ]),
  ])
}

fn view_week_header(weeks: List(Date)) -> Element(Msg) {
  html.div([attribute.class("schedule-row schedule-row--head")], [
    html.div([attribute.class("schedule-cell schedule-cell--label")], []),
    element.fragment(
      list.map(weeks, fn(week) {
        html.div([attribute.class("schedule-cell schedule-cell--head")], [
          html.text(week_label(week)),
        ])
      }),
    ),
  ])
}

fn view_lane(lane: schedule_view.EngineerLane) -> Element(Msg) {
  let schedule_view.EngineerLane(name:, level:, cells:, ..) = lane
  html.div([attribute.class("schedule-row")], [
    html.div([attribute.class("schedule-cell schedule-cell--label")], [
      html.span([attribute.class("schedule-lane__name")], [html.text(name)]),
      html.span([attribute.class("schedule-lane__level")], [
        html.text("L" <> int.to_string(level)),
      ]),
    ]),
    element.fragment(list.map(cells, view_cell)),
  ])
}

fn view_cell(cell: schedule_view.CellState) -> Element(Msg) {
  case cell {
    schedule_view.OutsideRun ->
      html.div([attribute.class("schedule-cell schedule-cell--outside")], [
        html.text("·"),
      ])
    schedule_view.Idle ->
      html.div([attribute.class("schedule-cell schedule-cell--idle")], [
        html.text("–"),
      ])
    schedule_view.OnLeave ->
      html.div([attribute.class("schedule-cell schedule-cell--leave")], [
        html.text("leave"),
      ])
    schedule_view.Working(fraction:, over_allocated:) ->
      html.div([attribute.class(working_cell_class(fraction, over_allocated))], [
        html.text(int.to_string(float.round(fraction *. 100.0))),
      ])
  }
}

fn working_cell_class(fraction: Float, over_allocated: Bool) -> String {
  let band = case fraction {
    fraction if fraction <=. 0.25 -> "schedule-cell--f25"
    fraction if fraction <=. 0.5 -> "schedule-cell--f50"
    fraction if fraction <=. 0.8 -> "schedule-cell--f80"
    _ -> "schedule-cell--f100"
  }
  let over = case over_allocated {
    True -> " schedule-cell--oa"
    False -> ""
  }
  "schedule-cell " <> band <> over
}

fn view_gap_row(line: schedule_view.RequirementLine) -> Element(Msg) {
  html.div([attribute.class("schedule-row schedule-row--gap")], [
    html.div([attribute.class("schedule-cell schedule-cell--label")], [
      html.text(line_label(line.kind)),
    ]),
    element.fragment(list.map(line.gaps, view_gap_cell)),
  ])
}

fn view_gap_cell(gap: Float) -> Element(Msg) {
  case gap <=. 0.0 {
    True ->
      html.div([attribute.class("schedule-cell schedule-cell--g0")], [
        html.text("0"),
      ])
    False ->
      html.div([attribute.class("schedule-cell schedule-cell--gap")], [
        html.text(format_gap(gap)),
      ])
  }
}

fn format_gap(gap: Float) -> String {
  format_one_decimal(gap)
}

pub fn format_one_decimal(value: Float) -> String {
  let rounded = float.round(value *. 10.0)
  let whole = rounded / 10
  let tenths = int.modulo(int.absolute_value(rounded), 10) |> result.unwrap(0)
  int.to_string(whole) <> "." <> int.to_string(tenths)
}

fn week_label(date: Date) -> String {
  time.month_abbrev(date.month) <> " " <> int.to_string(date.day)
}
