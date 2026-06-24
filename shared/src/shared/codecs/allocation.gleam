//// JSON codec for `AllocationCommand` — the allocation aggregate's slice of the
//// command wire contract. `encode` tags each variant by its `op`; `decoder` returns
//// the field decoder for an `op` the allocation aggregate owns (`Error(Nil)` for any
//// other), so the top-level `codecs.command_decoder` can dispatch by tag and wrap
//// the result as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date, lenient_float_decoder}
import shared/types.{
  type AllocationCommand, AssignToProject, ChangeAllocationFraction, RollOff,
}

/// Encode an `AllocationCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: AllocationCommand) -> Json {
  case command {
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      json.object([
        #("op", json.string("assign_to_project")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("fraction", json.float(fraction)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      json.object([
        #("op", json.string("change_allocation_fraction")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("fraction", json.float(fraction)),
        #("effective", encode_date(effective)),
      ])
    RollOff(engineer_id:, project_id:, effective:) ->
      json.object([
        #("op", json.string("roll_off")),
        #("engineer_id", json.int(engineer_id)),
        #("project_id", json.int(project_id)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for an allocation `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(AllocationCommand), Nil) {
  case op {
    "assign_to_project" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use project_id <- decode.field("project_id", decode.int)
        use fraction <- decode.field("fraction", lenient_float_decoder())
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(AssignToProject(
          engineer_id:,
          project_id:,
          fraction:,
          valid_from:,
          valid_to:,
        ))
      })
    "change_allocation_fraction" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use project_id <- decode.field("project_id", decode.int)
        use fraction <- decode.field("fraction", lenient_float_decoder())
        use effective <- decode.field("effective", date_decoder())
        decode.success(ChangeAllocationFraction(
          engineer_id:,
          project_id:,
          fraction:,
          effective:,
        ))
      })
    "roll_off" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use project_id <- decode.field("project_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(RollOff(engineer_id:, project_id:, effective:))
      })
    _ -> Error(Nil)
  }
}
