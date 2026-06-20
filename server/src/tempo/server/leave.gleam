//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. `handle` routes the leave command to a named
//// operation that returns the `Fact`s it records; `command.dispatch` records them
//// (through `repository`) and persists the journal in ONE transaction. No HTTP —
//// never imports `wisp`.
////
//// `take_leave` records a bounded `EngineerOnLeave` fact. The
//// `leave_within_employment` PERIOD FK is the backstop — leave outside the
//// engineer's employment is rejected by the database.

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, TakeLeave}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}

/// Apply a leave-aggregate command: route it to its named operation, which returns
/// the facts it records. The dispatch `route` only ever sends leave commands here,
/// so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    TakeLeave(..) -> take_leave(command)
    _ ->
      panic as "leave.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record an engineer on leave of a kind over `[valid_from, valid_to)`, plus the
/// journal entry.
fn take_leave(command: Command) -> Result(List(Fact), OperationError) {
  let assert TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) = command
  Ok([
    fact.EngineerOnLeave(engineer_id:, kind:, from: valid_from, to: valid_to),
    fact.CommandHandled(
      operation: "take_leave",
      summary: "Engineer "
        <> int.to_string(engineer_id)
        <> " on "
        <> kind
        <> " leave over "
        <> operation.span(valid_from, valid_to),
      payload: codecs.encode_command(command),
    ),
  ])
}
