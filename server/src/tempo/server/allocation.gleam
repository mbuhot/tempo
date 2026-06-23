//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. `command.route` destructures each allocation command and
//// calls the matching operation here with its already-narrowed fields; the
//// operation returns the `Fact`s it records, and `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// `assign_to_project` records a fresh bounded allocation (`to: Some`);
//// `change_allocation_fraction` re-fractions the version in effect (`to: None`, the
//// repository's change); `roll_off` records `EngineerOffProject`, which the
//// repository implements as the cap.

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Record a fresh bounded allocation over `[valid_from, valid_to)`, with the journal
/// entry; the allocation is contained by both employment and the project via PERIOD
/// FKs.
pub fn assign_to_project(
  command: Command,
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  fraction fraction: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
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
pub fn change_allocation_fraction(
  command: Command,
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  fraction fraction: Float,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
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
pub fn roll_off(
  command: Command,
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
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
