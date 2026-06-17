//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. `handle` matches the leave commands, does ONLY
//// their temporal writes on the in-transaction connection, classifies any database
//// rejection, and returns the journal event(s) it produced; `command.dispatch`
//// owns the transaction and persists those events. No HTTP — never imports `wisp`.
////
//// `TakeLeave` is an Assert (write pattern 1): a plain insert of a bounded leave
//// fact. The `leave_within_employment` PERIOD FK is the backstop — leave outside
//// the engineer's employment is rejected by the database.

import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, TakeLeave}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a leave-aggregate command: run its temporal writes on the in-transaction
/// connection, classify any database rejection, and on success return the single
/// journal event it produced. Only the leave commands reach here (the dispatch
/// `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      sql.leave_take(conn, engineer_id, kind, valid_from, valid_to)
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// The journal event(s) an applied leave command produces.
fn events(command: Command) -> List(Event) {
  case command {
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) -> [
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
    ]
    _ -> []
  }
}
