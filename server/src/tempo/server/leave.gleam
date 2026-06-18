//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. `handle` routes the leave command to a named
//// operation that does ONLY its temporal write on the in-transaction connection and
//// classifies any database rejection; `command.dispatch` owns the transaction and
//// persists the journal event(s) `handle` returns. No HTTP — never imports `wisp`.
////
//// `take_leave` is an Assert (write pattern 1): a plain insert of a bounded leave
//// fact. The `leave_within_employment` PERIOD FK is the backstop — leave outside
//// the engineer's employment is rejected by the database.

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, TakeLeave}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a leave-aggregate command: route it to its named operation, which does its
/// temporal write and returns the journal event(s) it produced. The dispatch `route`
/// only ever sends leave commands here, so any other variant is a routing bug —
/// `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    TakeLeave(..) -> take_leave(conn, command)
    _ ->
      panic as "leave.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record an engineer on leave of a kind over a bounded period (Assert), then return
/// its journal event. The `leave_within_employment` PERIOD FK rejects leave outside
/// their employment.
fn take_leave(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) = command
  use _ <- operation.try(sql.leave_take(
    conn,
    engineer_id,
    kind,
    valid_from,
    valid_to,
  ))
  Ok([
    Event(
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
