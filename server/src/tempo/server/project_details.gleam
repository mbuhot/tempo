//// Domain: the project-details aggregate — the two edit-grouped facts that hang
//// off the project anchor (profile = title + summary; plan = budget +
//// target_completion). `command.route` destructures each Update* command and calls
//// the matching operation here with its already-narrowed fields; the operation
//// returns the audit entry and the `Fact`s it records, and `command.dispatch` hands
//// both to `repository` in ONE transaction. No HTTP — never imports `wisp`.
////
//// Each is recorded from `effective` onward; the repository makes that the current
//// version (a change, falling back to an open at start_project).

import gleam/float
import gleam/int
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Record a new project profile from `effective` onward, with its journal entry.
pub fn update_project_profile(
  command: Command,
  project_id project_id: Int,
  title title: String,
  summary summary: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "update_project_profile",
        summary: "Update profile for project "
          <> int.to_string(project_id)
          <> " ("
          <> title
          <> ") from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.ProjectProfile(
          project_id: fact.ProjectId(project_id),
          title:,
          summary:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Record a new project plan from `effective` onward, with its journal entry.
pub fn update_project_plan(
  command: Command,
  project_id project_id: Int,
  budget budget: Float,
  target_completion target_completion: Date,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "update_project_plan",
        summary: "Update plan for project "
          <> int.to_string(project_id)
          <> " (budget "
          <> float.to_string(budget)
          <> ") from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.ProjectPlan(
          project_id: fact.ProjectId(project_id),
          budget:,
          target_completion:,
          from: effective,
        ),
      ],
    ),
  )
}
