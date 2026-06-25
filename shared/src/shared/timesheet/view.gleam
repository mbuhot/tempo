//// The timesheet read models and their JSON codecs: the weekly grid
//// (`TimesheetCell`/`TimesheetWeekRow`/`TimesheetWeek`) and the POST
//// /api/timesheet `WriteRequest` contract. Pure Gleam, no target-specific deps,
//// so they round-trip on both ends of the JSON-over-HTTP boundary. Dates
//// serialise as ISO-8601 "YYYY-MM-DD" strings and `hours` decodes leniently (a
//// JS client may serialise a whole `Float` as an integer-looking number).

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire

/// One cell of the weekly timesheet grid: a single (project, day) slot. `allocated`
/// is the cell's editability — true when an allocation to the project covers `date`
/// AND the engineer is not on leave that day; the grid disables the cell when false.
/// `hours` is the hours already logged for that cell (0.0 if none yet).
pub type TimesheetCell {
  TimesheetCell(date: Date, allocated: Bool, hours: Float)
}

/// One row of the weekly timesheet grid: a project the engineer is allocated to on
/// any day of the week, with one `cell` per column day. `cells` are ordered Mon..Sun,
/// aligned with the enclosing `TimesheetWeek.days`.
pub type TimesheetWeekRow {
  TimesheetWeekRow(project_id: Int, project: String, cells: List(TimesheetCell))
}

/// An engineer's weekly timesheet grid: the Mon..Sun `days` columns of the week
/// starting `week_start`, and one `row` per project allocated on any day of the week.
/// `days` is the 7 column dates (or `[]` when there are no rows). `rows` is empty
/// when the engineer has nothing to log all week (e.g. on leave all week).
pub type TimesheetWeek {
  TimesheetWeek(
    engineer_id: Int,
    week_start: Date,
    days: List(Date),
    rows: List(TimesheetWeekRow),
  )
}

/// A validated timesheet write request: which engineer logs how many hours
/// against which project on which day. This decoded payload IS the POST
/// /api/timesheet contract — the client encodes it, the server decodes it, and
/// the domain logs it.
pub type WriteRequest {
  WriteRequest(engineer_id: Int, project_id: Int, day: Date, hours: Float)
}

/// Encode a `TimesheetCell` (one grid cell) as a JSON object.
pub fn encode_timesheet_cell(cell: TimesheetCell) -> Json {
  let TimesheetCell(date:, allocated:, hours:) = cell
  json.object([
    #("date", wire.encode_date(date)),
    #("allocated", json.bool(allocated)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a `TimesheetCell` from a JSON object. `hours` is read leniently (a JS
/// client may serialise a whole `Float` as an integer-looking number).
pub fn timesheet_cell_decoder() -> Decoder(TimesheetCell) {
  use date <- decode.field("date", wire.date_decoder())
  use allocated <- decode.field("allocated", decode.bool)
  use hours <- decode.field("hours", wire.lenient_float_decoder())
  decode.success(TimesheetCell(date:, allocated:, hours:))
}

/// Encode a `TimesheetWeekRow` (one project's row of cells) as a JSON object.
pub fn encode_timesheet_week_row(row: TimesheetWeekRow) -> Json {
  let TimesheetWeekRow(project_id:, project:, cells:) = row
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("cells", json.array(cells, encode_timesheet_cell)),
  ])
}

/// Decode a `TimesheetWeekRow` from a JSON object.
pub fn timesheet_week_row_decoder() -> Decoder(TimesheetWeekRow) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use cells <- decode.field("cells", decode.list(timesheet_cell_decoder()))
  decode.success(TimesheetWeekRow(project_id:, project:, cells:))
}

/// Encode a `TimesheetWeek` (the weekly timesheet grid) to JSON.
pub fn encode_timesheet_week(week: TimesheetWeek) -> Json {
  let TimesheetWeek(engineer_id:, week_start:, days:, rows:) = week
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("week_start", wire.encode_date(week_start)),
    #("days", json.array(days, wire.encode_date)),
    #("rows", json.array(rows, encode_timesheet_week_row)),
  ])
}

/// Decode a `TimesheetWeek` from JSON.
pub fn timesheet_week_decoder() -> Decoder(TimesheetWeek) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use week_start <- decode.field("week_start", wire.date_decoder())
  use days <- decode.field("days", decode.list(wire.date_decoder()))
  use rows <- decode.field("rows", decode.list(timesheet_week_row_decoder()))
  decode.success(TimesheetWeek(engineer_id:, week_start:, days:, rows:))
}

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
    #("day", wire.encode_date(day)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a timesheet write request `{engineer_id, project_id, day, hours}` from
/// the POST /api/timesheet body. Pairs with `encode_write_request`: `day` is an
/// ISO-8601 "YYYY-MM-DD" string and `hours` is read leniently (a JS client may
/// serialise a whole `Float` as an integer-looking number).
pub fn write_request_decoder() -> Decoder(WriteRequest) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use project_id <- decode.field("project_id", decode.int)
  use day <- decode.field("day", wire.date_decoder())
  use hours <- decode.field("hours", wire.lenient_float_decoder())
  decode.success(WriteRequest(engineer_id:, project_id:, day:, hours:))
}
