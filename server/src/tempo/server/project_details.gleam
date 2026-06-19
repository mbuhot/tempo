//// Domain: the project-details aggregate — the two edit-grouped facts that hang
//// off the project anchor (profile = title + summary; plan = budget +
//// target_completion). `handle` routes each Update* command to a named operation
//// that does ONLY its temporal write on the in-transaction connection and
//// classifies any database rejection; `command.dispatch` owns the transaction and
//// persists the journal event(s) `handle` returns. No HTTP — never imports `wisp`.
////
//// Both facts are APPEND-ONLY (their period is `recorded_during` / `planned_during`),
//// so an edit is a temporal Change in ONE statement — a FOR PORTION OF UPDATE (like
//// rate_card/salary): it re-sets the [effective, NULL) portion of the row covering
//// `effective`, and PG carves off the unchanged [start, effective) remainder as its
//// own row. The founding rows are opened at start_project, so the covering row
//// always exists.

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, UpdateProjectPlan, UpdateProjectProfile}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a project-details command: route it to its named operation, which does its
/// temporal write and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends these two commands here, so any other variant is a
/// routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    UpdateProjectProfile(..) -> update_project_profile(conn, command)
    UpdateProjectPlan(..) -> update_project_plan(conn, command)
    _ ->
      panic as "project_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record a new project profile from `effective` onward (Change on project_profile):
/// close the covering row at `effective`, open a new full [effective, NULL) row,
/// then return its journal event.
fn update_project_profile(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateProjectProfile(project_id:, title:, summary:, effective:) =
    command
  use _ <- operation.try(sql.project_profile_revise(
    conn,
    project_id,
    effective,
    title,
    summary,
  ))
  Ok([
    Event(
      operation: "update_project_profile",
      summary: "Update profile for project "
        <> int.to_string(project_id)
        <> " ("
        <> title
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Record a new project plan from `effective` onward (Change on project_plan):
/// close the covering row at `effective`, open a new full [effective, NULL) row,
/// then return its journal event.
fn update_project_plan(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateProjectPlan(
    project_id:,
    budget:,
    target_completion:,
    effective:,
  ) = command
  use _ <- operation.try(sql.project_plan_revise(
    conn,
    project_id,
    effective,
    budget,
    target_completion,
  ))
  Ok([
    Event(
      operation: "update_project_plan",
      summary: "Update plan for project "
        <> int.to_string(project_id)
        <> " (budget "
        <> float.to_string(budget)
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
