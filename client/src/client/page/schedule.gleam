//// Schedule — the allocation timeline: every active project's engineer lanes
//// over 12 weekly columns with per-requirement gap rows, a portfolio stats
//// strip, and the project inspector + what-if scenario preview/apply.
////
//// The inspector lets a manager nominate a candidate into an open seat or
//// drag a project's run window; every draft accumulates in `scenario` and is
//// re-evaluated through the server's rollback-preview endpoint (debounced,
//// rail-scrub style) so the grid always shows what the batch WOULD produce
//// before "Apply changes" commits it as one write.

import client/api
import client/page.{type OutMsg}
import client/route.{type Route}
import client/scheduler
import client/time
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/time/calendar.{type Date}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/access as perm
import shared/allocation/command as allocation_command
import shared/command.{type Command}
import shared/engagement/command as engagement_command
import shared/schedule/view.{type Schedule} as schedule_view
import shared/wire

pub type State {
  Loading
  Loaded(Schedule)
  Failed(detail: String)
}

pub type Model {
  Model(
    as_of: Date,
    actor: String,
    state: State,
    scenario: List(Command),
    preview_on: Bool,
    selected: Option(Int),
    preview_token: Int,
    inspector: Option(Inspector),
    outcomes: List(schedule_view.OperationOutcome),
    applying: Bool,
    apply_error: Option(String),
  )
}

/// The selected project's editable run-window text and any open seat picker.
pub type Inspector {
  Inspector(run_from: String, run_to: String, picker: Option(OpenPicker))
}

/// A seat nomination in progress: which seat (by its position in the
/// project's team list — two open seats can share a level and fraction, so
/// the level/fraction pair alone cannot tell them apart), the window to
/// assign the candidate over, and the candidate fetch's state.
pub type OpenPicker {
  OpenPicker(
    seat_index: Int,
    level: Int,
    fraction: Float,
    from: Date,
    to: Date,
    candidates: CandidateState,
  )
}

pub type CandidateState {
  CandidatesLoading
  CandidatesLoaded(List(schedule_view.Candidate))
  CandidatesFailed(detail: String)
}

pub type RunBound {
  RunFrom
  RunTo
}

pub type Msg {
  Fetched(as_of: Date, result: Result(Schedule, rsvp.Error(String)))
  ProjectSelected(project_id: Int)
  PreviewToggled
  RunDateEdited(which: RunBound, value: String)
  NominateOpened(index: Int, level: Int, fraction: Float)
  CandidatesFetched(
    result: Result(List(schedule_view.Candidate), rsvp.Error(String)),
  )
  CandidatePicked(candidate: schedule_view.Candidate)
  PickerClosed
  DraftRemoved(index: Int)
  PreviewSettled(token: Int)
  Previewed(
    token: Int,
    result: Result(schedule_view.PreviewResult, rsvp.Error(String)),
  )
  ApplyRequested
  Applied(result: Result(schedule_view.PreviewResult, rsvp.Error(String)))
  ScenarioDiscarded
}

pub fn init(
  _route: Route,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  #(
    Model(
      as_of:,
      actor:,
      state: Loading,
      scenario: [],
      preview_on: False,
      selected: None,
      preview_token: 0,
      inspector: None,
      outcomes: [],
      applying: False,
      apply_error: None,
    ),
    fetch(as_of),
  )
}

pub fn refetch(
  model: Model,
  as_of: Date,
  actor: String,
) -> #(Model, Effect(Msg)) {
  let model = Model(..model, as_of:, actor:)
  case model.preview_on, model.scenario {
    True, [_, ..] -> #(model, preview_effect(model))
    _, _ -> #(model, fetch(as_of))
  }
}

fn fetch(as_of: Date) -> Effect(Msg) {
  api.get(
    "/api/schedule?as_of=" <> time.iso_date(as_of),
    schedule_view.schedule_decoder(),
    fn(result) { Fetched(as_of:, result:) },
  )
}

fn fetch_candidates(
  as_of: Date,
  project_id: Int,
  level: Int,
  from: Date,
  to: Date,
) -> Effect(Msg) {
  api.get(
    "/api/schedule/candidates?as_of="
      <> time.iso_date(as_of)
      <> "&project="
      <> int.to_string(project_id)
      <> "&level="
      <> int.to_string(level)
      <> "&from="
      <> time.iso_date(from)
      <> "&to="
      <> time.iso_date(to),
    decode.list(schedule_view.candidate_decoder()),
    CandidatesFetched,
  )
}

fn preview_body(as_of: Date, scenario: List(Command)) -> json.Json {
  json.object([
    #("as_of", wire.encode_date(as_of)),
    #("operations", json.array(scenario, command.encode_command)),
  ])
}

fn preview_effect(model: Model) -> Effect(Msg) {
  let token = model.preview_token
  api.post(
    "/api/schedule/preview",
    preview_body(model.as_of, model.scenario),
    schedule_view.preview_result_decoder(),
    fn(result) { Previewed(token:, result:) },
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Fetched(as_of:, result:) ->
      case model.as_of == as_of {
        False -> #(model, effect.none(), [])
        True -> {
          let state = case result {
            Ok(schedule) -> Loaded(schedule)
            Error(error) -> Failed(api.describe_error(error))
          }
          #(Model(..model, state:), effect.none(), [])
        }
      }
    ProjectSelected(project_id:) -> #(
      Model(
        ..model,
        selected: Some(project_id),
        inspector: inspector_for(model, project_id),
      ),
      effect.none(),
      [],
    )
    PreviewToggled -> {
      let preview_on = !model.preview_on
      case preview_on, model.scenario {
        False, _ -> #(Model(..model, preview_on:), fetch(model.as_of), [])
        True, [] -> #(Model(..model, preview_on:), effect.none(), [])
        True, _ -> bump_preview(Model(..model, preview_on:))
      }
    }
    RunDateEdited(which:, value:) ->
      case model.inspector {
        None -> #(model, effect.none(), [])
        Some(inspector) -> {
          let updated = case which {
            RunFrom -> Inspector(..inspector, run_from: value)
            RunTo -> Inspector(..inspector, run_to: value)
          }
          let model = Model(..model, inspector: Some(updated))
          case
            time.parse_iso_date(updated.run_from),
            time.parse_iso_date(updated.run_to)
          {
            Ok(from), Ok(to) -> schedule_reschedule_draft(model, from, to)
            _, _ -> #(model, effect.none(), [])
          }
        }
      }
    NominateOpened(index:, level:, fraction:) ->
      case model.selected, model.inspector {
        Some(project_id), Some(inspector) ->
          case
            time.parse_iso_date(inspector.run_from),
            time.parse_iso_date(inspector.run_to)
          {
            Ok(run_from), Ok(run_to) -> {
              let from = max_date(model.as_of, run_from)
              let picker =
                OpenPicker(
                  seat_index: index,
                  level:,
                  fraction:,
                  from:,
                  to: run_to,
                  candidates: CandidatesLoading,
                )
              #(
                Model(
                  ..model,
                  inspector: Some(Inspector(..inspector, picker: Some(picker))),
                ),
                fetch_candidates(model.as_of, project_id, level, from, run_to),
                [],
              )
            }
            _, _ -> #(model, effect.none(), [])
          }
        _, _ -> #(model, effect.none(), [])
      }
    CandidatesFetched(result:) -> {
      let inspector =
        option.map(model.inspector, fn(inspector) {
          case inspector.picker {
            None -> inspector
            Some(picker) -> {
              let candidates = case result {
                Ok(candidates) -> CandidatesLoaded(candidates)
                Error(error) ->
                  CandidatesFailed(detail: api.describe_error(error))
              }
              Inspector(
                ..inspector,
                picker: Some(OpenPicker(..picker, candidates:)),
              )
            }
          }
        })
      #(Model(..model, inspector:), effect.none(), [])
    }
    CandidatePicked(candidate:) ->
      case model.selected, model.inspector {
        Some(project_id), Some(inspector) ->
          case inspector.picker {
            Some(picker) -> {
              let draft =
                command.AllocationCommand(allocation_command.AssignToProject(
                  engineer_id: candidate.engineer_id,
                  project_id:,
                  fraction: picker.fraction,
                  valid_from: picker.from,
                  valid_to: picker.to,
                ))
              let scenario = list.append(model.scenario, [draft])
              let inspector = Inspector(..inspector, picker: None)
              schedule_preview_or_clear(
                Model(
                  ..model,
                  scenario:,
                  inspector: Some(inspector),
                  preview_on: True,
                ),
              )
            }
            None -> #(model, effect.none(), [])
          }
        _, _ -> #(model, effect.none(), [])
      }
    PickerClosed -> {
      let inspector =
        option.map(model.inspector, fn(inspector) {
          Inspector(..inspector, picker: None)
        })
      #(Model(..model, inspector:), effect.none(), [])
    }
    DraftRemoved(index:) ->
      schedule_preview_or_clear(
        Model(..model, scenario: remove_at(model.scenario, index)),
      )
    PreviewSettled(token:) ->
      case token == model.preview_token {
        True -> #(model, preview_effect(model), [])
        False -> #(model, effect.none(), [])
      }
    Previewed(token:, result:) ->
      case token == model.preview_token {
        False -> #(model, effect.none(), [])
        True ->
          case result {
            Ok(preview_result) -> #(
              Model(
                ..model,
                state: Loaded(preview_result.schedule),
                outcomes: preview_result.outcomes,
              ),
              effect.none(),
              [],
            )
            Error(error) -> #(
              Model(..model, state: Failed(api.describe_error(error))),
              effect.none(),
              [],
            )
          }
      }
    ApplyRequested -> #(
      Model(..model, applying: True, apply_error: None),
      api.post(
        "/api/schedule/apply",
        preview_body(model.as_of, model.scenario),
        schedule_view.preview_result_decoder(),
        Applied,
      ),
      [],
    )
    Applied(result:) ->
      case result {
        Ok(_) -> #(
          Model(
            ..model,
            scenario: [],
            outcomes: [],
            applying: False,
            preview_on: False,
            apply_error: None,
          ),
          fetch(model.as_of),
          [page.OperationCommitted],
        )
        Error(error) -> #(
          Model(
            ..model,
            applying: False,
            apply_error: Some(api.describe_error(error)),
          ),
          effect.none(),
          [],
        )
      }
    ScenarioDiscarded -> #(
      Model(
        ..model,
        scenario: [],
        outcomes: [],
        preview_on: False,
        apply_error: None,
      ),
      fetch(model.as_of),
      [],
    )
  }
}

fn inspector_for(model: Model, project_id: Int) -> Option(Inspector) {
  case model.state {
    Loaded(schedule) ->
      case
        list.find(schedule.projects, fn(project) {
          project.project_id == project_id
        })
      {
        Ok(project) ->
          Some(Inspector(
            run_from: time.iso_date(project.run_from),
            run_to: time.iso_date(project.run_to),
            picker: None,
          ))
        Error(Nil) -> None
      }
    _ -> None
  }
}

fn schedule_reschedule_draft(
  model: Model,
  from: Date,
  to: Date,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model.selected {
    None -> #(model, effect.none(), [])
    Some(project_id) -> {
      let without_prior =
        list.filter(model.scenario, fn(draft) {
          !is_reschedule_for(draft, project_id)
        })
      let scenario = case is_current_run(model, project_id, from, to) {
        True -> without_prior
        False ->
          list.append(without_prior, [
            command.EngagementCommand(engagement_command.RescheduleProject(
              project_id:,
              valid_from: from,
              valid_to: to,
            )),
          ])
      }
      schedule_preview_or_clear(Model(..model, scenario:, preview_on: True))
    }
  }
}

fn is_reschedule_for(draft: Command, project_id: Int) -> Bool {
  case draft {
    command.EngagementCommand(engagement_command.RescheduleProject(
      project_id: id,
      ..,
    )) -> id == project_id
    _ -> False
  }
}

fn is_current_run(model: Model, project_id: Int, from: Date, to: Date) -> Bool {
  case model.state {
    Loaded(schedule) ->
      case
        list.find(schedule.projects, fn(project) {
          project.project_id == project_id
        })
      {
        Ok(project) -> project.run_from == from && project.run_to == to
        Error(Nil) -> False
      }
    _ -> False
  }
}

fn schedule_preview_or_clear(
  model: Model,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model.scenario {
    [] -> #(model, fetch(model.as_of), [])
    _ -> bump_preview(model)
  }
}

fn bump_preview(model: Model) -> #(Model, Effect(Msg), List(OutMsg)) {
  let token = model.preview_token + 1
  #(
    Model(..model, preview_token: token),
    scheduler.after(150, PreviewSettled(token:)),
    [],
  )
}

fn max_date(a: Date, b: Date) -> Date {
  case time.date_to_day_index(a) > time.date_to_day_index(b) {
    True -> a
    False -> b
  }
}

fn remove_at(items: List(a), index: Int) -> List(a) {
  items
  |> list.index_map(fn(item, i) { #(i, item) })
  |> list.filter(fn(pair) { pair.0 != index })
  |> list.map(fn(pair) { pair.1 })
}

pub fn view(
  model: Model,
  _as_of: Date,
  permissions: Set(String),
) -> Element(Msg) {
  case model.state {
    Loading -> html.div([attribute.class("schedule schedule--loading")], [])
    Failed(detail:) ->
      html.div([attribute.class("schedule schedule--failed")], [
        html.text(detail),
      ])
    Loaded(schedule) -> view_loaded(model, schedule, permissions)
  }
}

fn view_loaded(
  model: Model,
  schedule: Schedule,
  permissions: Set(String),
) -> Element(Msg) {
  let schedule_view.Schedule(weeks:, projects:, ..) = schedule
  html.div([attribute.class("schedule")], [
    view_stats(model, projects, permissions),
    html.div([attribute.class("detail-grid")], [
      html.div(
        [attribute.class("schedule-projects")],
        list.map(projects, view_project(model, weeks, _)),
      ),
      view_inspector(model, projects, permissions),
    ]),
  ])
}

// --- Stats strip -------------------------------------------------------------

fn view_stats(
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

fn view_project(
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
  html.section([attribute.class(class)], [
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

fn format_one_decimal(value: Float) -> String {
  let rounded = float.round(value *. 10.0)
  let whole = rounded / 10
  let tenths = int.modulo(int.absolute_value(rounded), 10) |> result.unwrap(0)
  int.to_string(whole) <> "." <> int.to_string(tenths)
}

fn pct(fraction: Float) -> String {
  int.to_string(float.round(fraction *. 100.0)) <> "%"
}

fn week_label(date: Date) -> String {
  time.month_abbrev(date.month) <> " " <> int.to_string(date.day)
}

// --- Inspector ------------------------------------------------------------

fn view_inspector(
  model: Model,
  projects: List(schedule_view.ProjectSchedule),
  permissions: Set(String),
) -> Element(Msg) {
  case model.selected, model.inspector {
    Some(project_id), Some(inspector) ->
      case
        list.find(projects, fn(project) { project.project_id == project_id })
      {
        Ok(project) ->
          view_inspector_panel(model, project, inspector, permissions)
        Error(Nil) -> element.none()
      }
    _, _ -> element.none()
  }
}

fn view_inspector_panel(
  model: Model,
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
      view_team_section(model, project, permissions),
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

fn view_team_section(
  model: Model,
  project: schedule_view.ProjectSchedule,
  permissions: Set(String),
) -> Element(Msg) {
  html.div([attribute.class("schedule-seats")], [
    html.div([attribute.class("schedule-seats__title")], [html.text("Team")]),
    element.fragment(
      project.team
      |> list.index_map(fn(seat, index) { #(index, seat) })
      |> list.map(fn(pair) { view_seat(model, permissions, pair.0, pair.1) }),
    ),
    view_drafted_seats(model, project.project_id),
  ])
}

fn view_seat(
  model: Model,
  permissions: Set(String),
  index: Int,
  seat: schedule_view.Seat,
) -> Element(Msg) {
  case seat {
    schedule_view.FilledSeat(level:, name:, fraction:, ..) ->
      html.div([attribute.class("schedule-seat schedule-seat--filled")], [
        html.span([attribute.class("schedule-seat__level")], [
          html.text("L" <> int.to_string(level)),
        ]),
        html.span([attribute.class("schedule-seat__name")], [html.text(name)]),
        html.span([attribute.class("schedule-seat__fraction")], [
          html.text(pct(fraction)),
        ]),
      ])
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
          attribute.class("btn btn--ghost btn--sm schedule-seat__nominate"),
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
          html.text(format_one_decimal(candidate.proficiency)),
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
  format_one_decimal(float.clamp(value /. 7.0 *. 100.0, min: 0.0, max: 100.0))
  <> "%"
}
