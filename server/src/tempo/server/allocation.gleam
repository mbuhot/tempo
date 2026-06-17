//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. `handle` matches the allocation commands, does ONLY their
//// temporal writes on the in-transaction connection, classifies any database
//// rejection, and returns the journal event(s) it produced; `command.dispatch`
//// owns the transaction and persists those events. No HTTP — never imports `wisp`.
////
//// The operations span three of the four write patterns: `AssignToProject` is an
//// Assert over [valid_from, valid_to) (the allocation is contained by both
//// employment and project via PERIOD FKs); `ChangeAllocationFraction` is a Change
//// (FOR PORTION OF … TO NULL, re-fraction from a date onward, scheduled-future
//// versions untouched); `RollOff` is a Close (DELETE … FOR PORTION OF, capping one
//// allocation from a date).

import gleam/float
import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{
  type Command, AssignToProject, ChangeAllocationFraction, RollOff,
}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an allocation-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection, and on success
/// return the single journal event it produced. Only the allocation commands
/// reach here (the dispatch `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) ->
      sql.allocation_assign(
        conn,
        engineer_id,
        project_id,
        valid_from,
        fraction,
        valid_to,
      )
      |> result.replace(Nil)
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) ->
      sql.allocation_change_fraction(
        conn,
        engineer_id,
        project_id,
        effective,
        fraction,
      )
      |> result.replace(Nil)
    RollOff(engineer_id:, project_id:, effective:) ->
      sql.allocation_close(conn, engineer_id, project_id, effective)
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// The journal event(s) an applied allocation command produces.
fn events(command: Command) -> List(Event) {
  case command {
    AssignToProject(
      engineer_id:,
      project_id:,
      fraction:,
      valid_from:,
      valid_to:,
    ) -> [
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
    ]
    ChangeAllocationFraction(engineer_id:, project_id:, fraction:, effective:) -> [
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
    ]
    RollOff(engineer_id:, project_id:, effective:) -> [
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
    ]
    _ -> []
  }
}
