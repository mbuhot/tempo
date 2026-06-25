//// The leave aggregate's write command type and its JSON codec. `encode` tags each
//// variant by its `op`; `decoder` returns the field decoder for an `op` the leave
//// aggregate owns (`Error(Nil)` for any other), so `shared/command.command_decoder`
//// can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type LeaveCommand {
  /// Put an engineer on leave of a kind for a period.
  TakeLeave(engineer_id: Int, kind: String, valid_from: Date, valid_to: Date)
}

/// Encode a `LeaveCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: LeaveCommand) -> Json {
  case command {
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("take_leave")),
        #("engineer_id", json.int(engineer_id)),
        #("kind", json.string(kind)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
  }
}

/// The field decoder for a leave `op`, or `Error(Nil)` for an op this aggregate does
/// not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(LeaveCommand), Nil) {
  case op {
    "take_leave" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use kind <- decode.field("kind", decode.string)
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(TakeLeave(engineer_id:, kind:, valid_from:, valid_to:))
      })
    _ -> Error(Nil)
  }
}
