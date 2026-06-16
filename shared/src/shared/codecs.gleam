//// Gleam/json encoders and gleam/dynamic/decode decoders
//// for the shared API types. Pure Gleam, no target-specific deps, so they compile and
//// round-trip on both ends of the JSON-over-HTTP boundary (ADR-005). Round-trip
//// identity (`encode |> decode == value`) is asserted by the layer-4 codec tests.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/result
import gleam/string
import shared/types.{
  type AsOf, type BoardRow, type BoardSnapshot, type Date, type Engagement,
  type TimesheetDay, type TimesheetLine, AsOf, BoardRow, BoardSnapshot, Date,
  OnLeave, OnProject, TimesheetDay, TimesheetLine, Unassigned,
}

// --- Date -------------------------------------------------------------------
// Carried on the wire as an ISO-8601 "YYYY-MM-DD" string: unambiguous, compact,
// and exactly round-trippable for the integer-component Date type.

/// Encode a `Date` as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_date(date: Date) -> Json {
  let Date(year:, month:, day:) = date
  json.string(pad4(year) <> "-" <> pad2(month) <> "-" <> pad2(day))
}

/// Decode an ISO-8601 "YYYY-MM-DD" string into a `Date`.
pub fn date_decoder() -> Decoder(Date) {
  use text <- decode.then(decode.string)
  case parse_iso_date(text) {
    Ok(date) -> decode.success(date)
    Error(Nil) -> decode.failure(Date(0, 1, 1), "Date")
  }
}

fn parse_iso_date(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use day <- result.try(int.parse(day))
      Ok(Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}

// --- AsOf -------------------------------------------------------------------

/// Encode an `AsOf` instant as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_as_of(as_of: AsOf) -> Json {
  let AsOf(year:, month:, day:) = as_of
  encode_date(Date(year:, month:, day:))
}

/// Decode an ISO-8601 "YYYY-MM-DD" string into an `AsOf`.
pub fn as_of_decoder() -> Decoder(AsOf) {
  use date <- decode.then(date_decoder())
  let Date(year:, month:, day:) = date
  decode.success(AsOf(year:, month:, day:))
}

// --- Engagement -------------------------------------------------------------
// A tagged object: `status` discriminates the three situations; the remaining
// fields belong to the active variant.

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
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    OnLeave(kind:, valid_from:, valid_to:) ->
      json.object([
        #("status", json.string("on_leave")),
        #("kind", json.string(kind)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    Unassigned -> json.object([#("status", json.string("unassigned"))])
  }
}

/// Decode a JSON number as a `Float`, accepting an integer-valued number too.
///
/// JSON has a single number type, and JavaScript serialises a whole `Float`
/// (e.g. `4.0`) as the integer-looking `4`, whereas Erlang emits `4.0`. A strict
/// `decode.float` then rejects the JS-encoded whole number — which is exactly how
/// a Float fails to cross the JS client -> Erlang server boundary (e.g. timesheet
/// `hours` of `4`). Decoding every Float through this tolerant decoder makes the
/// contract symmetric regardless of which target encoded the value.
pub fn lenient_float_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Decode an `Engagement` from its tagged JSON object.
pub fn engagement_decoder() -> Decoder(Engagement) {
  use status <- decode.field("status", decode.string)
  case status {
    "on_project" -> {
      use project <- decode.field("project", decode.string)
      use client <- decode.field("client", decode.string)
      use fraction <- decode.field("fraction", lenient_float_decoder())
      use day_rate <- decode.field("day_rate", lenient_float_decoder())
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
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
      use valid_from <- decode.field("valid_from", date_decoder())
      use valid_to <- decode.field("valid_to", date_decoder())
      decode.success(OnLeave(kind:, valid_from:, valid_to:))
    }
    "unassigned" -> decode.success(Unassigned)
    _ -> decode.failure(Unassigned, "Engagement")
  }
}

// --- BoardRow ---------------------------------------------------------------

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

// --- BoardSnapshot ----------------------------------------------------------

/// Encode a board snapshot to JSON for the HTTP API.
pub fn encode_board_snapshot(snapshot: BoardSnapshot) -> Json {
  let BoardSnapshot(as_of:, rows:) = snapshot
  json.object([
    #("as_of", encode_as_of(as_of)),
    #("rows", json.array(rows, encode_board_row)),
  ])
}

/// Decode a board snapshot from a JSON-derived dynamic value.
pub fn board_snapshot_decoder() -> Decoder(BoardSnapshot) {
  use as_of <- decode.field("as_of", as_of_decoder())
  use rows <- decode.field("rows", decode.list(board_row_decoder()))
  decode.success(BoardSnapshot(as_of:, rows:))
}

// --- TimesheetLine ----------------------------------------------------------

/// Encode a `TimesheetLine` as a JSON object.
pub fn encode_timesheet_line(line: TimesheetLine) -> Json {
  let TimesheetLine(
    project_id:,
    project:,
    fraction:,
    hours:,
    valid_from:,
    valid_to:,
  ) = line
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("fraction", json.float(fraction)),
    #("hours", json.float(hours)),
    #("valid_from", encode_date(valid_from)),
    #("valid_to", encode_date(valid_to)),
  ])
}

/// Decode a `TimesheetLine` from a JSON object.
pub fn timesheet_line_decoder() -> Decoder(TimesheetLine) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use fraction <- decode.field("fraction", lenient_float_decoder())
  use hours <- decode.field("hours", lenient_float_decoder())
  use valid_from <- decode.field("valid_from", date_decoder())
  use valid_to <- decode.field("valid_to", date_decoder())
  decode.success(TimesheetLine(
    project_id:,
    project:,
    fraction:,
    hours:,
    valid_from:,
    valid_to:,
  ))
}

// --- TimesheetDay -----------------------------------------------------------

/// Encode a `TimesheetDay` (the timesheet form for one day) to JSON.
pub fn encode_timesheet_day(day: TimesheetDay) -> Json {
  let TimesheetDay(engineer_id:, as_of:, lines:) = day
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("as_of", encode_as_of(as_of)),
    #("lines", json.array(lines, encode_timesheet_line)),
  ])
}

/// Decode a `TimesheetDay` from JSON.
pub fn timesheet_day_decoder() -> Decoder(TimesheetDay) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use as_of <- decode.field("as_of", as_of_decoder())
  use lines <- decode.field("lines", decode.list(timesheet_line_decoder()))
  decode.success(TimesheetDay(engineer_id:, as_of:, lines:))
}

// --- Timesheet write --------------------------------------------------------
// The POST /api/timesheet request body and the typed error body the handler
// returns on rejection. Kept here so the client and server share one contract:
// the client encodes the request with `encode_write_request` and the server's
// `timesheet.write_request_decoder` reads exactly these keys.

/// Encode a timesheet write request `{engineer_id, project_id, day, hours}` for
/// POST /api/timesheet, with `day` as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_write_request(
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  day day: Date,
  hours hours: Float,
) -> Json {
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("project_id", json.int(project_id)),
    #("day", encode_date(day)),
    #("hours", json.float(hours)),
  ])
}

/// Pull the human-readable `detail` out of the handler's typed error body
/// (`{error, detail}`), e.g. the PERIOD-FK rejection reason. Returns `Error(Nil)`
/// if the body is not that shape.
pub fn decode_error_detail(body: String) -> Result(String, Nil) {
  let detail_decoder = {
    use detail <- decode.field("detail", decode.string)
    decode.success(detail)
  }
  json.parse(body, detail_decoder)
  |> result.replace_error(Nil)
}
