//// Domain: the project capability-demand aggregate — a project's demand for
//// `quantity` engineers at `target_level` proficiency in a capability,
//// versioned over time. `command.route` destructures the capability-demand
//// command and calls the operation here with its already-narrowed fields; the
//// operation returns the `Fact`s it records, and `command.dispatch` records
//// them (through `repository`) and persists the journal in ONE transaction.
//// No HTTP — never imports `wisp`.
////
//// `set_project_capability` is the bounded surgical write: a FOR-PORTION-OF
//// set on `(project_id, capability_id)` over `[valid_from, valid_to)`,
//// mirroring `project_requirement.set_project_requirement`.

import gleam/float
import gleam/int
import gleam/time/calendar.{type Date}
import shared/command.{ProjectCapabilityCommand} as gateway
import shared/project_capability/command.{
  type ProjectCapabilityCommand, SetProjectCapability,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route a project-capability command to its operation, returning the audit
/// entry and the facts it records. Exhaustive over `ProjectCapabilityCommand`.
pub fn route(
  command: ProjectCapabilityCommand,
) -> Result(Recorded, OperationError) {
  case command {
    SetProjectCapability(
      project_id:,
      capability_id:,
      target_level:,
      quantity:,
      valid_from:,
      valid_to:,
    ) ->
      set_project_capability(
        command,
        project_id:,
        capability_id:,
        target_level:,
        quantity:,
        valid_from:,
        valid_to:,
      )
  }
}

/// Set a project's capability demand for a bounded window `[valid_from,
/// valid_to)`, with the journal entry.
pub fn set_project_capability(
  command: ProjectCapabilityCommand,
  project_id project_id: Int,
  capability_id capability_id: Int,
  target_level target_level: Int,
  quantity quantity: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "set_project_capability",
        summary: "Set capability demand: "
          <> float.to_string(quantity)
          <> "x L"
          <> int.to_string(target_level)
          <> " capability "
          <> int.to_string(capability_id)
          <> " on project "
          <> int.to_string(project_id)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: gateway.encode_command(ProjectCapabilityCommand(command)),
      ),
      facts: [
        fact.ProjectCapabilityRequired(
          project_id: fact.ProjectId(project_id),
          capability_id: fact.CapabilityId(capability_id),
          target_level:,
          quantity:,
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}
