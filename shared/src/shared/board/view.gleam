//// The org-board read models and their JSON codecs: an engineer's `Engagement`,
//// one `BoardRow`, the unstaffed-lane `UnstaffedProject`, and the whole
//// `BoardSnapshot` for a date. Pure Gleam, no target-specific deps, so they
//// round-trip on both ends of the JSON-over-HTTP boundary. Dates serialise as
//// ISO-8601 "YYYY-MM-DD" strings. `BoardSnapshot` embeds the leave balances from
//// `shared/leave/view`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/leave/view as leave_view
import shared/wire

/// An engineer's situation on the org board for a date. Leave takes precedence
/// over an allocation in the read model: an engineer covered by a leave fact is
/// `OnLeave`, otherwise one `OnProject` per project they are allocated to. An
/// employed engineer with no allocation on the date is `Unassigned`.
pub type Engagement {
  /// Allocated to a project. `day_rate` is the resolved charge rate as a plain
  /// value.
  OnProject(
    project: String,
    client: String,
    fraction: Float,
    day_rate: Float,
    valid_from: Date,
    valid_to: Date,
  )
  /// Covered by a leave fact; the underlying allocation is suppressed. `kind` is
  /// the leave kind (annual | sick | parental | …); the period is the leave window.
  OnLeave(kind: String, valid_from: Date, valid_to: Date)
  /// Employed but not allocated (and not on leave) as of the date.
  Unassigned
}

/// One line on the org board: an engineer, their level on the date, and their
/// situation. Engaged engineers contribute one row per project; on-leave engineers
/// contribute a single `OnLeave` row.
pub type BoardRow {
  BoardRow(engineer: String, level: Int, engagement: Engagement)
}

/// A project with no engineers staffed on the board's date — a candidate for the
/// Assign modal, which pre-fills `project_id` to skip a title->id round-trip.
pub type UnstaffedProject {
  UnstaffedProject(project_id: Int, title: String, client: String)
}

/// The whole org board for a single date: the engagement rows, each employed
/// engineer's leave balances as of that date, and the unstaffed projects lane.
pub type BoardSnapshot {
  BoardSnapshot(
    date: Date,
    rows: List(BoardRow),
    balances: List(leave_view.LeaveBalance),
    unstaffed: List(UnstaffedProject),
  )
}

/// Encode an `Engagement` as a tagged JSON object keyed by `status`.
pub fn encode_engagement(engagement: Engagement) -> Json {
  case engagement {
    OnProject(project:, client:, fraction:, day_rate:, valid_from:, valid_to:) ->
      json.object([
        #("status", json.string("on_project")),
        #("project", json.string(project)),
        #("client", json.string(client)),
        #("fraction", json.float(fraction)),
        #("day_rate", json.float(day_rate)),
        #("valid_from", wire.encode_date(valid_from)),
        #("valid_to", wire.encode_date(valid_to)),
      ])
    OnLeave(kind:, valid_from:, valid_to:) ->
      json.object([
        #("status", json.string("on_leave")),
        #("kind", json.string(kind)),
        #("valid_from", wire.encode_date(valid_from)),
        #("valid_to", wire.encode_date(valid_to)),
      ])
    Unassigned -> json.object([#("status", json.string("unassigned"))])
  }
}

/// Decode an `Engagement` from its tagged JSON object.
pub fn engagement_decoder() -> Decoder(Engagement) {
  use status <- decode.field("status", decode.string)
  case status {
    "on_project" -> {
      use project <- decode.field("project", decode.string)
      use client <- decode.field("client", decode.string)
      use fraction <- decode.field("fraction", wire.lenient_float_decoder())
      use day_rate <- decode.field("day_rate", wire.lenient_float_decoder())
      use valid_from <- decode.field("valid_from", wire.date_decoder())
      use valid_to <- decode.field("valid_to", wire.date_decoder())
      decode.success(OnProject(
        project:,
        client:,
        fraction:,
        day_rate:,
        valid_from:,
        valid_to:,
      ))
    }
    "on_leave" -> {
      use kind <- decode.field("kind", decode.string)
      use valid_from <- decode.field("valid_from", wire.date_decoder())
      use valid_to <- decode.field("valid_to", wire.date_decoder())
      decode.success(OnLeave(kind:, valid_from:, valid_to:))
    }
    "unassigned" -> decode.success(Unassigned)
    _ -> decode.failure(Unassigned, "Engagement")
  }
}

/// Encode a `BoardRow` as a JSON object.
pub fn encode_board_row(row: BoardRow) -> Json {
  let BoardRow(engineer:, level:, engagement:) = row
  json.object([
    #("engineer", json.string(engineer)),
    #("level", json.int(level)),
    #("engagement", encode_engagement(engagement)),
  ])
}

/// Decode a `BoardRow` from a JSON object.
pub fn board_row_decoder() -> Decoder(BoardRow) {
  use engineer <- decode.field("engineer", decode.string)
  use level <- decode.field("level", decode.int)
  use engagement <- decode.field("engagement", engagement_decoder())
  decode.success(BoardRow(engineer:, level:, engagement:))
}

/// Encode an `UnstaffedProject` (one unstaffed-lane entry) as a JSON object.
pub fn encode_unstaffed_project(project: UnstaffedProject) -> Json {
  let UnstaffedProject(project_id:, title:, client:) = project
  json.object([
    #("project_id", json.int(project_id)),
    #("title", json.string(title)),
    #("client", json.string(client)),
  ])
}

/// Decode an `UnstaffedProject` from a JSON object.
pub fn unstaffed_project_decoder() -> Decoder(UnstaffedProject) {
  use project_id <- decode.field("project_id", decode.int)
  use title <- decode.field("title", decode.string)
  use client <- decode.field("client", decode.string)
  decode.success(UnstaffedProject(project_id:, title:, client:))
}

/// Encode a board snapshot to JSON for the HTTP API.
pub fn encode_board_snapshot(snapshot: BoardSnapshot) -> Json {
  let BoardSnapshot(date:, rows:, balances:, unstaffed:) = snapshot
  json.object([
    #("date", wire.encode_date(date)),
    #("rows", json.array(rows, encode_board_row)),
    #("balances", json.array(balances, leave_view.encode_leave_balance)),
    #("unstaffed", json.array(unstaffed, encode_unstaffed_project)),
  ])
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Decoder(BoardSnapshot) {
  use date <- decode.field("date", wire.date_decoder())
  use rows <- decode.field("rows", decode.list(board_row_decoder()))
  use balances <- decode.field(
    "balances",
    decode.list(leave_view.leave_balance_decoder()),
  )
  use unstaffed <- decode.field(
    "unstaffed",
    decode.list(unstaffed_project_decoder()),
  )
  decode.success(BoardSnapshot(date:, rows:, balances:, unstaffed:))
}
