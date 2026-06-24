//// JSON codec for `EngineerCommand` — the engineer aggregate's slice of the command
//// wire contract (ARCHITECTURE.md: one handler, understood in isolation). `encode`
//// tags each variant by its `op`; `decoder` returns the field decoder for an `op`
//// the engineer aggregate owns (`Error(Nil)` for any other), so the top-level
//// `codecs.command_decoder` can dispatch by tag and wrap the result as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date}
import shared/types.{
  type EngineerCommand, OnboardEngineer, Promote, TerminateEmployment,
}

/// Encode an `EngineerCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: EngineerCommand) -> Json {
  case command {
    OnboardEngineer(name:, level:, effective:) ->
      json.object([
        #("op", json.string("onboard_engineer")),
        #("name", json.string(name)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    Promote(engineer_id:, level:, effective:) ->
      json.object([
        #("op", json.string("promote")),
        #("engineer_id", json.int(engineer_id)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    TerminateEmployment(engineer_id:, effective:) ->
      json.object([
        #("op", json.string("terminate_employment")),
        #("engineer_id", json.int(engineer_id)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for an engineer `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(EngineerCommand), Nil) {
  case op {
    "onboard_engineer" ->
      Ok({
        use name <- decode.field("name", decode.string)
        use level <- decode.field("level", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(OnboardEngineer(name:, level:, effective:))
      })
    "promote" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use level <- decode.field("level", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(Promote(engineer_id:, level:, effective:))
      })
    "terminate_employment" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(TerminateEmployment(engineer_id:, effective:))
      })
    _ -> Error(Nil)
  }
}
