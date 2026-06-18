//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. `handle` routes each allocation command to a named operation
//// that does ONLY its temporal write on the in-transaction connection and classifies
//// any database rejection; `command.dispatch` owns the transaction and persists the
//// journal event(s) `handle` returns. No HTTP — never imports `wisp`.
////
//// The operations span three of the four write patterns: `assign_to_project` is an
//// Assert over [valid_from, valid_to) (contained by both employment and project via
//// PERIOD FKs); `change_allocation_fraction` is a Change (FOR PORTION OF … TO NULL,
//// re-fraction from a date onward, scheduled-future versions untouched); `roll_off`
//// is a Close (DELETE … FOR PORTION OF, capping one allocation from a date).

import gleam/float
import gleam/int
import pog
import shared/codecs
import shared/types.{
  type Command, AssignToProject, ChangeAllocationFraction, RollOff,
}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an allocation-aggregate command: route it to its named operation, which does
/// its temporal write and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends allocation commands here, so any other variant is a routing
/// bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    AssignToProject(..) -> assign_to_project(conn, command)
    ChangeAllocationFraction(..) -> change_allocation_fraction(conn, command)
    RollOff(..) -> roll_off(conn, command)
    _ ->
      panic as "allocation.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Assign an engineer to a project at a fraction over [valid_from, valid_to)
/// (Assert), then return its journal event; the allocation is contained by both
/// employment and the project via PERIOD FKs.
fn assign_to_project(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert AssignToProject(
    engineer_id:,
    project_id:,
    fraction:,
    valid_from:,
    valid_to:,
  ) = command
  use _ <- operation.try(sql.allocation_assign(
    conn,
    engineer_id,
    project_id,
    valid_from,
    fraction,
    valid_to,
  ))
  Ok([
    Event(
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
  ])
}

/// Re-fraction an engineer's allocation on a project from `effective` onward
/// (Change, FOR PORTION OF … TO NULL), then return its journal event; the `@>` guard
/// leaves a scheduled-future version untouched.
fn change_allocation_fraction(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert ChangeAllocationFraction(
    engineer_id:,
    project_id:,
    fraction:,
    effective:,
  ) = command
  use _ <- operation.try(sql.allocation_change_fraction(
    conn,
    engineer_id,
    project_id,
    effective,
    fraction,
  ))
  Ok([
    Event(
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
  ])
}

/// Roll an engineer off a project from `effective` (Close, DELETE … FOR PORTION OF),
/// capping that one allocation, then return its journal event.
fn roll_off(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert RollOff(engineer_id:, project_id:, effective:) = command
  use _ <- operation.try(sql.allocation_close(
    conn,
    engineer_id,
    project_id,
    effective,
  ))
  Ok([
    Event(
      operation: "roll_off",
      summary: "Roll engineer "
        <> int.to_string(engineer_id)
        <> " off project "
        <> int.to_string(project_id)
        <> " from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
