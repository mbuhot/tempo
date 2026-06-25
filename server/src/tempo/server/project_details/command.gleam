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
import shared/command.{ProjectDetailsCommand} as gateway
import shared/project_details/command.{
  type ProjectDetailsCommand, UpdateProjectPlan, UpdateProjectProfile,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route a project-details command to its operation, returning the audit entry and
/// the facts it records. Exhaustive over `ProjectDetailsCommand`.
pub fn route(
  command: ProjectDetailsCommand,
) -> Result(Recorded, OperationError) {
  case command {
    UpdateProjectProfile(project_id:, title:, summary:, effective:) ->
      update_project_profile(command, project_id:, title:, summary:, effective:)
    UpdateProjectPlan(project_id:, budget:, target_completion:, effective:) ->
      update_project_plan(
        command,
        project_id:,
        budget:,
        target_completion:,
        effective:,
      )
  }
}

/// Record a new project profile from `effective` onward, with its journal entry.
pub fn update_project_profile(
  command: ProjectDetailsCommand,
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
        payload: gateway.encode_command(ProjectDetailsCommand(command)),
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
  command: ProjectDetailsCommand,
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
        payload: gateway.encode_command(ProjectDetailsCommand(command)),
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
