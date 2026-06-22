//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. `handle` routes each allocation command to a named operation
//// that returns the `Fact`s it records; `command.dispatch` records them (through
//// `repository`) and persists the journal in ONE transaction. No HTTP — never
//// imports `wisp`.
////
//// `assign_to_project` records a fresh bounded allocation (`to: Some`);
//// `change_allocation_fraction` re-fractions the version in effect (`to: None`, the
//// repository's change); `roll_off` records `EngineerOffProject`, which the
//// repository implements as the cap.

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import pog
import shared/codecs
import shared/types.{
  type Command, AssignToProject, ChangeAllocationFraction, RollOff,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Apply an allocation-aggregate command: route it to its named operation, which
/// returns the audit entry and facts it records. The dispatch `route` only ever
/// sends allocation commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    AssignToProject(..) -> assign_to_project(command)
    ChangeAllocationFraction(..) -> change_allocation_fraction(command)
    RollOff(..) -> roll_off(command)
    _ ->
      panic as "allocation.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record a fresh bounded allocation over `[valid_from, valid_to)`, with the journal
/// entry; the allocation is contained by both employment and the project via PERIOD
/// FKs.
fn assign_to_project(command: Command) -> Result(Recorded, OperationError) {
  let assert AssignToProject(
    engineer_id:,
    project_id:,
    fraction:,
    valid_from:,
    valid_to:,
  ) = command
  Ok(
    Recorded(
      entry: Event(
        operation: "assign_to_project",
        summary: "Assign engineer "
          <> int.to_string(engineer_id)
          <> " to project "
          <> int.to_string(project_id)
          <> " at "
          <> float.to_string(fraction)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerAllocatedToProject(
          engineer_id: fact.EngineerId(engineer_id),
          project_id: fact.ProjectId(project_id),
          fraction:,
          from: valid_from,
          to: Some(valid_to),
        ),
      ],
    ),
  )
}

/// Re-fraction an engineer's allocation from `effective` onward, with the journal
/// entry.
fn change_allocation_fraction(
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert ChangeAllocationFraction(
    engineer_id:,
    project_id:,
    fraction:,
    effective:,
  ) = command
  Ok(
    Recorded(
      entry: Event(
        operation: "change_allocation_fraction",
        summary: "Change engineer "
          <> int.to_string(engineer_id)
          <> " allocation on project "
          <> int.to_string(project_id)
          <> " to "
          <> float.to_string(fraction)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerAllocatedToProject(
          engineer_id: fact.EngineerId(engineer_id),
          project_id: fact.ProjectId(project_id),
          fraction:,
          from: effective,
          to: None,
        ),
      ],
    ),
  )
}

/// Roll an engineer off a project from `effective`, with the journal entry.
fn roll_off(command: Command) -> Result(Recorded, OperationError) {
  let assert RollOff(engineer_id:, project_id:, effective:) = command
  Ok(
    Recorded(
      entry: Event(
        operation: "roll_off",
        summary: "Roll engineer "
          <> int.to_string(engineer_id)
          <> " off project "
          <> int.to_string(project_id)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerOffProject(
          engineer_id: fact.EngineerId(engineer_id),
          project_id: fact.ProjectId(project_id),
          from: effective,
        ),
      ],
    ),
  )
}
