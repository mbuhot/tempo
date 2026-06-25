//// The project capacity-requirement aggregate's write command type and its JSON
//// codec (a project's demand for FTE at a level over a bounded window). `encode`
//// tags the variant by its `op`; `decoder` returns the field decoder for an `op`
//// this aggregate owns (`Error(Nil)` for any other), so
//// `shared/command.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date, lenient_float_decoder}

pub type ProjectRequirementCommand {
  /// Set a project's capacity requirement (demand) at a level for a bounded
  /// window: a FOR-PORTION-OF write on `(project_id, level)`, splitting the
  /// requirement row into before/during/after. `quantity` is fractional FTE.
  SetProjectRequirement(
    project_id: Int,
    level: Int,
    quantity: Float,
    valid_from: Date,
    valid_to: Date,
  )
}

/// Encode a `ProjectRequirementCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: ProjectRequirementCommand) -> Json {
  case command {
    SetProjectRequirement(
      project_id:,
      level:,
      quantity:,
      valid_from:,
      valid_to:,
    ) ->
      json.object([
        #("op", json.string("set_project_requirement")),
        #("project_id", json.int(project_id)),
        #("level", json.int(level)),
        #("quantity", json.float(quantity)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
  }
}

/// The field decoder for a project-requirement `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(ProjectRequirementCommand), Nil) {
  case op {
    "set_project_requirement" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use level <- decode.field("level", decode.int)
        use quantity <- decode.field("quantity", lenient_float_decoder())
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(SetProjectRequirement(
          project_id:,
          level:,
          quantity:,
          valid_from:,
          valid_to:,
        ))
      })
    _ -> Error(Nil)
  }
}
