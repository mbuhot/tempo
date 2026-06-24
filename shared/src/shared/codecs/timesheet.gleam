//// JSON codec for `TimesheetCommand` — the timesheet aggregate's slice of the
//// command wire contract (a single-cell log and the whole-week atomic write).
//// `encode` tags each variant by its `op`; `decoder` returns the field decoder for
//// an `op` the timesheet aggregate owns (`Error(Nil)` for any other). The
//// `TimesheetEntry` element codec lives here too, since only `LogWeek` carries it.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date, lenient_float_decoder}
import shared/types.{
  type TimesheetCommand, type TimesheetEntry, LogTimesheet, LogWeek,
  TimesheetEntry,
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
