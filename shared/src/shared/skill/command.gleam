//// The skill aggregate's write command type and its JSON codec — the skill-catalog
//// slice of the command wire contract. `encode` tags each variant by its `op`;
//// `decoder` returns the field decoder for an `op` the skill aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type SkillCommand {
  CreateSkill(name: String, summary: String, effective: Date)
  DefineSkill(skill_id: Int, name: String, summary: String, effective: Date)
  RetireSkill(skill_id: Int, effective: Date)
}

/// Encode a `SkillCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: SkillCommand) -> Json {
  case command {
    CreateSkill(name:, summary:, effective:) ->
      json.object([
        #("op", json.string("create_skill")),
        #("name", json.string(name)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    DefineSkill(skill_id:, name:, summary:, effective:) ->
      json.object([
        #("op", json.string("define_skill")),
        #("skill_id", json.int(skill_id)),
        #("name", json.string(name)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    RetireSkill(skill_id:, effective:) ->
      json.object([
        #("op", json.string("retire_skill")),
        #("skill_id", json.int(skill_id)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a skill `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(SkillCommand), Nil) {
  case op {
    "create_skill" ->
      Ok({
        use name <- decode.field("name", decode.string)
        use summary <- decode.field("summary", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(CreateSkill(name:, summary:, effective:))
      })
    "define_skill" ->
      Ok({
        use skill_id <- decode.field("skill_id", decode.int)
        use name <- decode.field("name", decode.string)
        use summary <- decode.field("summary", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(DefineSkill(skill_id:, name:, summary:, effective:))
      })
    "retire_skill" ->
      Ok({
        use skill_id <- decode.field("skill_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(RetireSkill(skill_id:, effective:))
      })
    _ -> Error(Nil)
  }
}
