//// The project aggregate's write command type and its JSON codec: the two
//// edit-grouped facts (profile = title + summary; plan = budget +
//// target_completion) plus the capacity-requirement demand (a project's demand
//// for FTE at a level over a bounded window). `encode` tags each variant by its
//// `op`; `decoder` returns the field decoder for an `op` this aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can
//// dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire.{date_decoder, encode_date, lenient_float_decoder}

pub type ProjectCommand {
  /// Record a new profile for a project effective from a date: close the
  /// `project_profile` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `title`/`summary` (a temporal Change on the
  /// append-only project_profile fact). `title` is the project's human-facing
  /// name.
  UpdateProjectProfile(
    project_id: Int,
    title: String,
    summary: String,
    effective: Date,
  )
  /// Record a new plan for a project effective from a date: close the
  /// `project_plan` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `budget`/`target_completion` (a temporal
  /// Change on the append-only project_plan fact). `budget` is a money amount.
  UpdateProjectPlan(
    project_id: Int,
    budget: Money,
    target_completion: Date,
    effective: Date,
  )
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

/// Encode a `ProjectCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: ProjectCommand) -> Json {
  case command {
    UpdateProjectProfile(project_id:, title:, summary:, effective:) ->
      json.object([
        #("op", json.string("update_project_profile")),
        #("project_id", json.int(project_id)),
        #("title", json.string(title)),
        #("summary", json.string(summary)),
        #("effective", encode_date(effective)),
      ])
    UpdateProjectPlan(project_id:, budget:, target_completion:, effective:) ->
      json.object([
        #("op", json.string("update_project_plan")),
        #("project_id", json.int(project_id)),
        #("budget", money.encode(budget)),
        #("target_completion", encode_date(target_completion)),
        #("effective", encode_date(effective)),
      ])
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

/// The field decoder for a project `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(ProjectCommand), Nil) {
  case op {
    "update_project_profile" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use title <- decode.field("title", decode.string)
        use summary <- decode.field("summary", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateProjectProfile(
          project_id:,
          title:,
          summary:,
          effective:,
        ))
      })
    "update_project_plan" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use budget <- decode.field("budget", money.decoder())
        use target_completion <- decode.field(
          "target_completion",
          date_decoder(),
        )
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateProjectPlan(
          project_id:,
          budget:,
          target_completion:,
          effective:,
        ))
      })
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
