//// The project-details aggregate's write command type and its JSON codec (the two
//// edit-grouped facts: profile = title + summary; plan = budget + target_completion).
//// `encode` tags each variant by its `op`; `decoder` returns the field decoder for
//// an `op` this aggregate owns (`Error(Nil)` for any other), so
//// `shared/command.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date, lenient_float_decoder}

pub type ProjectDetailsCommand {
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
    budget: Float,
    target_completion: Date,
    effective: Date,
  )
}

/// Encode a `ProjectDetailsCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: ProjectDetailsCommand) -> Json {
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
        #("budget", json.float(budget)),
        #("target_completion", encode_date(target_completion)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a project-details `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(ProjectDetailsCommand), Nil) {
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
        use budget <- decode.field("budget", lenient_float_decoder())
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
    _ -> Error(Nil)
  }
}
