//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. `command.route` forwards each `AllocationCommand` to
//// `route` here, which destructures it and calls the matching operation with its
//// already-narrowed fields; the operation returns the `Fact`s it records, and
//// `command.dispatch` records them (through `repository`) and persists the journal
//// in ONE transaction. No HTTP — never imports `wisp`.
////
//// `assign_to_project` records a fresh bounded allocation (`to: Some`);
//// `change_allocation_fraction` re-fractions the version in effect (`to: None`, the
//// repository's change); `roll_off` records `EngineerOffProject`, which the
//// repository implements as the cap.

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{
  type AllocationCommand, AllocationCommand, AssignToProject,
  ChangeAllocationFraction, RollOff,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/sql

/// Route an allocation command to its operation, returning the audit entry and the
/// facts it records. The `case` is exhaustive over `AllocationCommand`, so a new
/// allocation command with no arm is a compile error. `conn` is threaded for the
/// temporal precondition checks `assign_to_project` runs before recording.
pub fn route(
  conn: pog.Connection,
  command: AllocationCommand,
) -> Result(Recorded, OperationError) {
  case command {
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      assign_to_project(
        conn,
        command,
        engineer_id:,
        project_id:,
        fraction:,
        valid_from:,
        valid_to:,
      )
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      change_allocation_fraction(
        command,
        engineer_id:,
        project_id:,
        fraction:,
        effective:,
      )
    RollOff(engineer_id:, project_id:, effective:) ->
      roll_off(command, engineer_id:, project_id:, effective:)
  }
}

/// Record a fresh bounded allocation over `[valid_from, valid_to)`, with the journal
/// entry. The engineer must be employed and the project running across the WHOLE
/// window — checked here for clear `EngineerNotEmployed`/`ProjectNotRunning` errors
/// before the write; the `allocation_within_employment` / `allocation_within_project`
/// PERIOD FKs still backstop it at the database.
pub fn assign_to_project(
  conn: pog.Connection,
  command: AllocationCommand,
  engineer_id engineer_id: Int,
  project_id project_id: Int,
  fraction fraction: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  use _ <- validate_engineer_employed(conn, engineer_id, valid_from, valid_to)
  use _ <- validate_project_running(conn, project_id, valid_from, valid_to)
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
        payload: codecs.encode_command(AllocationCommand(command)),
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

/// Continue only if the engineer is employed across the whole `[valid_from,
/// valid_to)` window (the `engineer_employment_during` query returns at least one
/// row); otherwise refuse with `EngineerNotEmployed`.
fn validate_engineer_employed(
  conn: pog.Connection,
  engineer_id: Int,
  valid_from: Date,
  valid_to: Date,
  then continue: fn(Nil) -> Result(Recorded, OperationError),
) -> Result(Recorded, OperationError) {
  use returned <- operation.try(sql.engineer_employment_during(
    conn,
    engineer_id,
    valid_from,
    valid_to,
  ))
  case returned.rows {
    [] ->
      Error(operation.EngineerNotEmployed(engineer_id:, valid_from:, valid_to:))
    [_, ..] -> continue(Nil)
  }
}

/// Continue only if the project's run covers the whole `[valid_from, valid_to)`
/// window (the `project_run_during` query returns at least one row); otherwise
/// refuse with `ProjectNotRunning`.
fn validate_project_running(
  conn: pog.Connection,
  project_id: Int,
  valid_from: Date,
  valid_to: Date,
  then continue: fn(Nil) -> Result(Recorded, OperationError),
) -> Result(Recorded, OperationError) {
  use returned <- operation.try(sql.project_run_during(
    conn,
    project_id,
    valid_from,
    valid_to,
  ))
  case returned.rows {
    [] ->
      Error(operation.ProjectNotRunning(project_id:, valid_from:, valid_to:))
    [_, ..] -> continue(Nil)
  }
}

/// Re-fraction an engineer's allocation from `effective` onward, with the journal
/// entry.
pub fn change_allocation_fraction(
  command: AllocationCommand,
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
        payload: codecs.encode_command(AllocationCommand(command)),
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
  command: AllocationCommand,
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
        payload: codecs.encode_command(AllocationCommand(command)),
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
