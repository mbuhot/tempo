//// The Schedule page's state machine: the model (grid load state, selection,
//// inspector, and the what-if scenario of drafted commands), the messages, and
//// init/refetch/update. Every draft accumulates in `scenario` and is re-evaluated
//// through the server's rollback-preview endpoint (debounced, rail-scrub style)
//// so the grid always shows what the batch WOULD produce before "Apply changes"
//// commits it as one write.

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
import gleam/time/calendar.{type Date}
import lustre/effect.{type Effect}
import rsvp
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
  RollOffDrafted(engineer_id: Int)
  FractionChanged(engineer_id: Int, value: String)
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
      case model.as_of == as_of, model.preview_on, model.scenario {
        False, _, _ -> #(model, effect.none(), [])
        True, True, [_, ..] -> #(model, effect.none(), [])
        True, _, _ -> {
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
    RollOffDrafted(engineer_id:) ->
      draft_team_change(model, engineer_id, fn(project_id) {
        command.AllocationCommand(allocation_command.RollOff(
          engineer_id:,
          project_id:,
          effective: model.as_of,
        ))
      })
    FractionChanged(engineer_id:, value:) ->
      case parse_team_fraction(value) {
        Error(Nil) -> #(model, effect.none(), [])
        Ok(fraction) ->
          draft_team_change(model, engineer_id, fn(project_id) {
            command.AllocationCommand(
              allocation_command.ChangeAllocationFraction(
                engineer_id:,
                project_id:,
                fraction:,
                effective: model.as_of,
              ),
            )
          })
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

fn draft_team_change(
  model: Model,
  engineer_id: Int,
  build_draft: fn(Int) -> Command,
) -> #(Model, Effect(Msg), List(OutMsg)) {
  case model.selected {
    None -> #(model, effect.none(), [])
    Some(project_id) -> {
      let draft = build_draft(project_id)
      let scenario =
        model.scenario
        |> list.filter(fn(existing) {
          !is_team_draft_for(existing, project_id, engineer_id)
        })
        |> list.append([draft])
      schedule_preview_or_clear(Model(..model, scenario:, preview_on: True))
    }
  }
}

fn is_team_draft_for(
  draft: Command,
  project_id: Int,
  engineer_id: Int,
) -> Bool {
  case draft {
    command.AllocationCommand(allocation_command.ChangeAllocationFraction(
      project_id: draft_project,
      engineer_id: draft_engineer,
      ..,
    )) -> draft_project == project_id && draft_engineer == engineer_id
    command.AllocationCommand(allocation_command.RollOff(
      project_id: draft_project,
      engineer_id: draft_engineer,
      ..,
    )) -> draft_project == project_id && draft_engineer == engineer_id
    _ -> False
  }
}

fn parse_team_fraction(raw: String) -> Result(Float, Nil) {
  case float.parse(raw) {
    Ok(value) -> Ok(float.clamp(value, min: 0.0, max: 1.0))
    Error(Nil) ->
      case int.parse(raw) {
        Ok(value) -> Ok(float.clamp(int.to_float(value), min: 0.0, max: 1.0))
        Error(Nil) -> Error(Nil)
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
