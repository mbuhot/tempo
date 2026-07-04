//// The engineer-skill aggregate's write command type and its JSON codec — the
//// skill-assessment slice of the command wire contract. `AssessSkill` records an
//// engineer's level on a skill effective from a date (the temporal `engineer_skill`
//// map); only a principal with `skills.assess` may run it. `encode` tags the
//// variant by its `op`; `decoder` returns the field decoder for an `op` this
//// aggregate owns.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type EngineerSkillCommand {
  /// Record `engineer_id`'s level on `skill_id` effective from a date, opening an
  /// open-ended assessed period.
  AssessSkill(engineer_id: Int, skill_id: Int, level: Int, effective: Date)
}

/// Encode an `EngineerSkillCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: EngineerSkillCommand) -> Json {
  case command {
    AssessSkill(engineer_id:, skill_id:, level:, effective:) ->
      json.object([
        #("op", json.string("assess_skill")),
        #("engineer_id", json.int(engineer_id)),
        #("skill_id", json.int(skill_id)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for an engineer-skill `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(EngineerSkillCommand), Nil) {
  case op {
    "assess_skill" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use skill_id <- decode.field("skill_id", decode.int)
        use level <- decode.field("level", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(AssessSkill(engineer_id:, skill_id:, level:, effective:))
      })
    _ -> Error(Nil)
  }
}
