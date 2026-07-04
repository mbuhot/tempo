//// The capability aggregate's write command type and its JSON codec — the
//// capability-taxonomy slice of the command wire contract. `encode` tags each
//// variant by its `op`; `decoder` returns the field decoder for an `op` the
//// capability aggregate owns (`Error(Nil)` for any other), so
//// `shared/command.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type CapabilityCommand {
  CreateCapability(name: String, summary: String, effective: Date)
  DefineCapability(
    capability_id: Int,
    name: String,
    summary: String,
    effective: Date,
  )
  RetireCapability(capability_id: Int, effective: Date)
  SetCapabilitySkill(
    capability_id: Int,
    skill_id: Int,
    weight: Int,
    effective: Date,
  )
  RemoveCapabilitySkill(capability_id: Int, skill_id: Int, effective: Date)
}

/// Encode a `CapabilityCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: CapabilityCommand) -> Json {
  case command {
    CreateCapability(name:, summary:, effective:) ->
      json.object([
        #("op", json.string("create_capability")),
        #("name", json.string(name)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    DefineCapability(capability_id:, name:, summary:, effective:) ->
      json.object([
        #("op", json.string("define_capability")),
        #("capability_id", json.int(capability_id)),
        #("name", json.string(name)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    RetireCapability(capability_id:, effective:) ->
      json.object([
        #("op", json.string("retire_capability")),
        #("capability_id", json.int(capability_id)),
        #("effective", encode_date(effective)),
      ])
    SetCapabilitySkill(capability_id:, skill_id:, weight:, effective:) ->
      json.object([
        #("op", json.string("set_capability_skill")),
        #("capability_id", json.int(capability_id)),
        #("skill_id", json.int(skill_id)),
        #("weight", json.int(weight)),
        #("effective", encode_date(effective)),
      ])
    RemoveCapabilitySkill(capability_id:, skill_id:, effective:) ->
      json.object([
        #("op", json.string("remove_capability_skill")),
        #("capability_id", json.int(capability_id)),
        #("skill_id", json.int(skill_id)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a capability `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(CapabilityCommand), Nil) {
  case op {
    "create_capability" ->
      Ok({
        use name <- decode.field("name", decode.string)
        use summary <- decode.field("summary", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(CreateCapability(name:, summary:, effective:))
      })
    "define_capability" ->
      Ok({
        use capability_id <- decode.field("capability_id", decode.int)
        use name <- decode.field("name", decode.string)
        use summary <- decode.field("summary", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(DefineCapability(
          capability_id:,
          name:,
          summary:,
          effective:,
        ))
      })
    "retire_capability" ->
      Ok({
        use capability_id <- decode.field("capability_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(RetireCapability(capability_id:, effective:))
      })
    "set_capability_skill" ->
      Ok({
        use capability_id <- decode.field("capability_id", decode.int)
        use skill_id <- decode.field("skill_id", decode.int)
        use weight <- decode.field("weight", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(SetCapabilitySkill(
          capability_id:,
          skill_id:,
          weight:,
          effective:,
        ))
      })
    "remove_capability_skill" ->
      Ok({
        use capability_id <- decode.field("capability_id", decode.int)
        use skill_id <- decode.field("skill_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(RemoveCapabilitySkill(
          capability_id:,
          skill_id:,
          effective:,
        ))
      })
    _ -> Error(Nil)
  }
}
