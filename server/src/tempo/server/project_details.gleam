//// Domain: the project-details aggregate — the two edit-grouped facts that hang
//// off the project anchor (profile = title + summary; plan = budget +
//// target_completion). `handle` routes each Update* command to a named operation
//// that returns the audit entry and the `Fact`s it records; `command.dispatch` hands
//// both to `repository` in ONE transaction. No HTTP — never imports `wisp`.
////
//// Each is recorded from `effective` onward; the repository makes that the current
//// version (a change, falling back to an open at start_project).

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, UpdateProjectPlan, UpdateProjectProfile}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Apply a project-details command: route it to its named operation, which returns
/// the audit entry and facts it records. The dispatch `route` only ever sends these
/// two commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    UpdateProjectProfile(..) -> update_project_profile(command)
    UpdateProjectPlan(..) -> update_project_plan(command)
    _ ->
      panic as "project_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record a new project profile from `effective` onward, with its journal entry.
fn update_project_profile(
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert UpdateProjectProfile(project_id:, title:, summary:, effective:) =
    command
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
        fact.ProjectProfile(project_id:, title:, summary:, from: effective),
      ],
    ),
  )
}

/// Record a new project plan from `effective` onward, with its journal entry.
fn update_project_plan(command: Command) -> Result(Recorded, OperationError) {
  let assert UpdateProjectPlan(
    project_id:,
    budget:,
    target_completion:,
    effective:,
  ) = command
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
          project_id:,
          budget:,
          target_completion:,
          from: effective,
        ),
      ],
    ),
  )
}
