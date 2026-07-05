//// The schedule read model and its JSON codecs: the weekly allocation timeline
//// (`Schedule`/`ProjectSchedule`/`EngineerLane`/`CellState`), per-requirement gap
//// lines, team seats, capability coverage, the what-if `PreviewResult`, and
//// `Candidate` rows for the finder. Pure Gleam, no target-specific deps, so it
//// round-trips on both ends of the JSON-over-HTTP boundary. Dates serialise as
//// ISO-8601 "YYYY-MM-DD" strings.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

/// One engineer's situation in one week column of a project's lane.
pub type CellState {
  /// The week falls outside the project's run window.
  OutsideRun
  /// Inside the run, but the engineer has no allocation covering the week.
  Idle
  /// Allocated `fraction` of the week; `over_allocated` when their total across
  /// all projects that week exceeds 1.0.
  Working(fraction: Float, over_allocated: Bool)
  /// Covered by a leave fact for the week; the allocation is suppressed.
  OnLeave
}

/// One engineer's row in a project's timeline: their label and one `CellState`
/// per week column.
pub type EngineerLane {
  EngineerLane(
    engineer_id: Int,
    name: String,
    level: Int,
    cells: List(CellState),
  )
}

/// What a requirement gap line demands: a plain level headcount, or a named
/// capability at a target level.
pub type LineKind {
  LevelLine(level: Int)
  CapabilityLine(capability_id: Int, name: String, target_level: Int)
}

/// A requirement gap row: its demand and the uncovered `Float` per week column.
pub type RequirementLine {
  RequirementLine(kind: LineKind, gaps: List(Float))
}

/// One seat in a project's team roster: filled by a named engineer, or open.
pub type Seat {
  FilledSeat(level: Int, engineer_id: Int, name: String, fraction: Float)
  OpenSeat(level: Int, fraction: Float)
}

/// A capability's demand and the team's best qualifying rollup for the
/// inspector's coverage chart.
pub type CapabilityCoverage {
  CapabilityCoverage(
    capability_id: Int,
    name: String,
    target_level: Int,
    team_proficiency: Float,
  )
}

/// One project's whole timeline: its run window, lanes, requirement gap lines,
/// team seats, capability coverage, and an optional annotation (e.g. a
/// what-if preview's rejection note).
pub type ProjectSchedule {
  ProjectSchedule(
    project_id: Int,
    title: String,
    client: String,
    run_from: Date,
    run_to: Date,
    lanes: List(EngineerLane),
    lines: List(RequirementLine),
    team: List(Seat),
    capabilities: List(CapabilityCoverage),
    annotation: Option(String),
  )
}

/// The whole timeline for a date: the week header and every overlapping
/// project's schedule.
pub type Schedule {
  Schedule(as_of: Date, weeks: List(Date), projects: List(ProjectSchedule))
}

/// What happened to one draft operation in a what-if batch.
pub type OperationOutcome {
  OperationApplied
  OperationRejected(detail: String)
}

/// The result of previewing (or applying) a batch of draft operations: the
/// schedule they would produce, and each operation's outcome.
pub type PreviewResult {
  PreviewResult(schedule: Schedule, outcomes: List(OperationOutcome))
}

/// One engineer candidate for a gap in the finder.
pub type Candidate {
  Candidate(
    engineer_id: Int,
    name: String,
    level: Int,
    proficiency: Float,
    free: Float,
    commitments: String,
  )
}

fn encode_cell(cell: CellState) -> Json {
  case cell {
    OutsideRun -> json.object([#("state", json.string("outside_run"))])
    Idle -> json.object([#("state", json.string("idle"))])
    OnLeave -> json.object([#("state", json.string("on_leave"))])
    Working(fraction:, over_allocated:) ->
      json.object([
        #("state", json.string("working")),
        #("fraction", json.float(fraction)),
        #("over_allocated", json.bool(over_allocated)),
      ])
  }
}

fn cell_decoder() -> Decoder(CellState) {
  use state <- decode.field("state", decode.string)
  case state {
    "outside_run" -> decode.success(OutsideRun)
    "idle" -> decode.success(Idle)
    "on_leave" -> decode.success(OnLeave)
    "working" -> {
      use fraction <- decode.field("fraction", wire.lenient_float_decoder())
      use over_allocated <- decode.field("over_allocated", decode.bool)
      decode.success(Working(fraction:, over_allocated:))
    }
    _ -> decode.failure(Idle, "CellState")
  }
}

fn encode_lane(lane: EngineerLane) -> Json {
  let EngineerLane(engineer_id:, name:, level:, cells:) = lane
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("cells", json.array(cells, encode_cell)),
  ])
}

fn lane_decoder() -> Decoder(EngineerLane) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use cells <- decode.field("cells", decode.list(cell_decoder()))
  decode.success(EngineerLane(engineer_id:, name:, level:, cells:))
}

fn encode_line_kind(kind: LineKind) -> Json {
  case kind {
    LevelLine(level:) ->
      json.object([
        #("kind", json.string("level")),
        #("level", json.int(level)),
      ])
    CapabilityLine(capability_id:, name:, target_level:) ->
      json.object([
        #("kind", json.string("capability")),
        #("capability_id", json.int(capability_id)),
        #("name", json.string(name)),
        #("target_level", json.int(target_level)),
      ])
  }
}

fn line_kind_decoder() -> Decoder(LineKind) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "level" -> {
      use level <- decode.field("level", decode.int)
      decode.success(LevelLine(level:))
    }
    "capability" -> {
      use capability_id <- decode.field("capability_id", decode.int)
      use name <- decode.field("name", decode.string)
      use target_level <- decode.field("target_level", decode.int)
      decode.success(CapabilityLine(capability_id:, name:, target_level:))
    }
    _ -> decode.failure(LevelLine(level: 0), "LineKind")
  }
}

fn encode_requirement_line(line: RequirementLine) -> Json {
  let RequirementLine(kind:, gaps:) = line
  json.object([
    #("kind", encode_line_kind(kind)),
    #("gaps", json.array(gaps, json.float)),
  ])
}

fn requirement_line_decoder() -> Decoder(RequirementLine) {
  use kind <- decode.field("kind", line_kind_decoder())
  use gaps <- decode.field("gaps", decode.list(wire.lenient_float_decoder()))
  decode.success(RequirementLine(kind:, gaps:))
}

fn encode_seat(seat: Seat) -> Json {
  case seat {
    FilledSeat(level:, engineer_id:, name:, fraction:) ->
      json.object([
        #("kind", json.string("filled")),
        #("level", json.int(level)),
        #("engineer_id", json.int(engineer_id)),
        #("name", json.string(name)),
        #("fraction", json.float(fraction)),
      ])
    OpenSeat(level:, fraction:) ->
      json.object([
        #("kind", json.string("open")),
        #("level", json.int(level)),
        #("fraction", json.float(fraction)),
      ])
  }
}

fn seat_decoder() -> Decoder(Seat) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "filled" -> {
      use level <- decode.field("level", decode.int)
      use engineer_id <- decode.field("engineer_id", decode.int)
      use name <- decode.field("name", decode.string)
      use fraction <- decode.field("fraction", wire.lenient_float_decoder())
      decode.success(FilledSeat(level:, engineer_id:, name:, fraction:))
    }
    "open" -> {
      use level <- decode.field("level", decode.int)
      use fraction <- decode.field("fraction", wire.lenient_float_decoder())
      decode.success(OpenSeat(level:, fraction:))
    }
    _ -> decode.failure(OpenSeat(level: 0, fraction: 0.0), "Seat")
  }
}

fn encode_capability_coverage(coverage: CapabilityCoverage) -> Json {
  let CapabilityCoverage(
    capability_id:,
    name:,
    target_level:,
    team_proficiency:,
  ) = coverage
  json.object([
    #("capability_id", json.int(capability_id)),
    #("name", json.string(name)),
    #("target_level", json.int(target_level)),
    #("team_proficiency", json.float(team_proficiency)),
  ])
}

fn capability_coverage_decoder() -> Decoder(CapabilityCoverage) {
  use capability_id <- decode.field("capability_id", decode.int)
  use name <- decode.field("name", decode.string)
  use target_level <- decode.field("target_level", decode.int)
  use team_proficiency <- decode.field(
    "team_proficiency",
    wire.lenient_float_decoder(),
  )
  decode.success(CapabilityCoverage(
    capability_id:,
    name:,
    target_level:,
    team_proficiency:,
  ))
}

fn encode_project_schedule(project: ProjectSchedule) -> Json {
  let ProjectSchedule(
    project_id:,
    title:,
    client:,
    run_from:,
    run_to:,
    lanes:,
    lines:,
    team:,
    capabilities:,
    annotation:,
  ) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("client", json.string(client)),
    #("run_from", wire.encode_date(run_from)),
    #("run_to", wire.encode_date(run_to)),
    #("lanes", json.array(lanes, encode_lane)),
    #("lines", json.array(lines, encode_requirement_line)),
    #("team", json.array(team, encode_seat)),
    #("capabilities", json.array(capabilities, encode_capability_coverage)),
    #("annotation", json.nullable(annotation, json.string)),
  ])
}

fn project_schedule_decoder() -> Decoder(ProjectSchedule) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use client <- decode.field("client", decode.string)
  use run_from <- decode.field("run_from", wire.date_decoder())
  use run_to <- decode.field("run_to", wire.date_decoder())
  use lanes <- decode.field("lanes", decode.list(lane_decoder()))
  use lines <- decode.field("lines", decode.list(requirement_line_decoder()))
  use team <- decode.field("team", decode.list(seat_decoder()))
  use capabilities <- decode.field(
    "capabilities",
    decode.list(capability_coverage_decoder()),
  )
  use annotation <- decode.field("annotation", decode.optional(decode.string))
  decode.success(ProjectSchedule(
    project_id:,
    title:,
    client:,
    run_from:,
    run_to:,
    lanes:,
    lines:,
    team:,
    capabilities:,
    annotation:,
  ))
}

/// Encode a `Schedule` to JSON for the HTTP API.
pub fn encode_schedule(schedule: Schedule) -> Json {
  let Schedule(as_of:, weeks:, projects:) = schedule
  json.object([
    #("as_of", wire.encode_date(as_of)),
    #("weeks", json.array(weeks, wire.encode_date)),
    #("projects", json.array(projects, encode_project_schedule)),
  ])
}

/// Decode a `Schedule` from a JSON-derived dynamic value.
pub fn schedule_decoder() -> Decoder(Schedule) {
  use as_of <- decode.field("as_of", wire.date_decoder())
  use weeks <- decode.field("weeks", decode.list(wire.date_decoder()))
  use projects <- decode.field(
    "projects",
    decode.list(project_schedule_decoder()),
  )
  decode.success(Schedule(as_of:, weeks:, projects:))
}

fn encode_operation_outcome(outcome: OperationOutcome) -> Json {
  case outcome {
    OperationApplied -> json.object([#("outcome", json.string("applied"))])
    OperationRejected(detail:) ->
      json.object([
        #("outcome", json.string("rejected")),
        #("detail", json.string(detail)),
      ])
  }
}

fn operation_outcome_decoder() -> Decoder(OperationOutcome) {
  use outcome <- decode.field("outcome", decode.string)
  case outcome {
    "applied" -> decode.success(OperationApplied)
    "rejected" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(OperationRejected(detail:))
    }
    _ -> decode.failure(OperationApplied, "OperationOutcome")
  }
}

/// Encode a `PreviewResult` to JSON for the HTTP API.
pub fn encode_preview_result(result: PreviewResult) -> Json {
  let PreviewResult(schedule:, outcomes:) = result
  json.object([
    #("schedule", encode_schedule(schedule)),
    #("outcomes", json.array(outcomes, encode_operation_outcome)),
  ])
}

/// Decode a `PreviewResult` from a JSON-derived dynamic value.
pub fn preview_result_decoder() -> Decoder(PreviewResult) {
  use schedule <- decode.field("schedule", schedule_decoder())
  use outcomes <- decode.field(
    "outcomes",
    decode.list(operation_outcome_decoder()),
  )
  decode.success(PreviewResult(schedule:, outcomes:))
}

/// Encode a `Candidate` to JSON for the HTTP API.
pub fn encode_candidate(candidate: Candidate) -> Json {
  let Candidate(engineer_id:, name:, level:, proficiency:, free:, commitments:) =
    candidate
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("proficiency", json.float(proficiency)),
    #("free", json.float(free)),
    #("commitments", json.string(commitments)),
  ])
}

/// Decode a `Candidate` from a JSON-derived dynamic value.
pub fn candidate_decoder() -> Decoder(Candidate) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use proficiency <- decode.field("proficiency", wire.lenient_float_decoder())
  use free <- decode.field("free", wire.lenient_float_decoder())
  use commitments <- decode.field("commitments", decode.string)
  decode.success(Candidate(
    engineer_id:,
    name:,
    level:,
    proficiency:,
    free:,
    commitments:,
  ))
}
