//// Domain: the project aggregate — the two edit-grouped facts that hang off the
//// project anchor (profile = title + summary; plan = budget + target_completion)
//// plus the capacity-requirement demand (a project's demand for `quantity` FTE at
//// a `level`, versioned over time). `command.route` destructures each project
//// command and calls the matching operation here with its already-narrowed
//// fields; the operation returns the audit entry and the `Fact`s it records, and
//// `command.dispatch` hands both to `repository` in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// The profile and plan are each recorded from `effective` onward; the
//// repository makes that the current version (a change, falling back to an open
//// at start_project). `set_project_requirement` is the bounded surgical write: a
//// FOR-PORTION-OF set on `(project_id, level)` over `[valid_from, valid_to)`,
//// mirroring `rate_card.adjust_rate_for_portion`.

import gleam/float
import gleam/int
import gleam/time/calendar.{type Date}
import shared/command.{ProjectCommand} as gateway
import shared/money.{type Money}
import shared/project/command.{
  type ProjectCommand, SetProjectRequirement, UpdateProjectPlan,
  UpdateProjectProfile,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route a project command to its operation, returning the audit entry and the
/// facts it records. Exhaustive over `ProjectCommand`.
pub fn route(command: ProjectCommand) -> Result(Recorded, OperationError) {
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
    SetProjectRequirement(
      project_id:,
      level:,
      quantity:,
      valid_from:,
      valid_to:,
    ) ->
      set_project_requirement(
        command,
        project_id:,
        level:,
        quantity:,
        valid_from:,
        valid_to:,
      )
  }
}

/// Record a new project profile from `effective` onward, with its journal entry.
pub fn update_project_profile(
  command: ProjectCommand,
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
        payload: gateway.encode_command(ProjectCommand(command)),
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
  command: ProjectCommand,
  project_id project_id: Int,
  budget budget: Money,
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
          <> money.to_string(budget)
          <> ") from "
          <> operation.iso(effective),
        payload: gateway.encode_command(ProjectCommand(command)),
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

/// Set a project's capacity requirement for a bounded window `[valid_from, valid_to)`,
/// with the journal entry.
pub fn set_project_requirement(
  command: ProjectCommand,
  project_id project_id: Int,
  level level: Int,
  quantity quantity: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "set_project_requirement",
        summary: "Set requirement: "
          <> float.to_string(quantity)
          <> "x L"
          <> int.to_string(level)
          <> " on project "
          <> int.to_string(project_id)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: gateway.encode_command(ProjectCommand(command)),
      ),
      facts: [
        fact.ProjectRequirement(
          project_id: fact.ProjectId(project_id),
          level:,
          quantity:,
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}
