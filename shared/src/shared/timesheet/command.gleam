//// The timesheet aggregate's write command type and its JSON codec (a single-cell
//// log and the whole-week atomic write). `encode` tags each variant by its `op`;
//// `decoder` returns the field decoder for an `op` the timesheet aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`. The `TimesheetEntry` element type and its codec
//// live here too, since only `LogWeek` carries it.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date, lenient_float_decoder}

pub type TimesheetCommand {
  /// Log hours an engineer worked on a project on a day.
  LogTimesheet(engineer_id: Int, project_id: Int, day: Date, hours: Float)
  /// Log a whole week's hours atomically: each entry sets one (project, day) cell
  /// for the engineer; an `hours` of 0.0 clears that cell. Every entry commits or
  /// none.
  LogWeek(engineer_id: Int, entries: List(TimesheetEntry))
}

/// One (project, day) entry of a `LogWeek` submission: the hours to set for that
/// cell. An `hours` of 0.0 clears the cell.
pub type TimesheetEntry {
  TimesheetEntry(project_id: Int, day: Date, hours: Float)
}

/// Encode a `TimesheetCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: TimesheetCommand) -> Json {
  case command {
    LogTimesheet(engineer_id:, project_id:, day:, hours:) ->
      json.object([
        #("op", json.string("log_timesheet")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("day", encode_date(day)),
        #("hours", json.float(hours)),
      ])
    LogWeek(engineer_id:, entries:) ->
      json.object([
        #("op", json.string("log_week")),
        #("engineer_id", json.int(engineer_id)),
        #("entries", json.array(entries, encode_entry)),
      ])
  }
}

/// The field decoder for a timesheet `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(TimesheetCommand), Nil) {
  case op {
    "log_timesheet" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use project_id <- decode.field("project_id", decode.int)
        use day <- decode.field("day", date_decoder())
        use hours <- decode.field("hours", lenient_float_decoder())
        decode.success(LogTimesheet(engineer_id:, project_id:, day:, hours:))
      })
    "log_week" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use entries <- decode.field("entries", decode.list(entry_decoder()))
        decode.success(LogWeek(engineer_id:, entries:))
      })
    _ -> Error(Nil)
  }
}

/// Encode a `TimesheetEntry` (one cell of a week submission) as a JSON object.
fn encode_entry(entry: TimesheetEntry) -> Json {
  let TimesheetEntry(project_id:, day:, hours:) = entry
  json.object([
    #("project_id", json.int(project_id)),
    #("day", encode_date(day)),
    #("hours", json.float(hours)),
  ])
}

/// Decode a `TimesheetEntry` from a JSON object. `hours` is read leniently (a JS
/// client may serialise a whole `Float` as an integer-looking number).
fn entry_decoder() -> Decoder(TimesheetEntry) {
  use project_id <- decode.field("project_id", decode.int)
  use day <- decode.field("day", date_decoder())
  use hours <- decode.field("hours", lenient_float_decoder())
  decode.success(TimesheetEntry(project_id:, day:, hours:))
}
