//// Domain: the client-details aggregate — the single edit-grouped fact that hangs
//// off the client anchor (its profile, which is just the NAME). `handle` routes the
//// UpdateClientProfile command to a named operation that does ONLY its temporal
//// write on the in-transaction connection and classifies any database rejection;
//// `command.dispatch` owns the transaction and persists the journal event(s)
//// `handle` returns. No HTTP — never imports `wisp`.
////
//// client_profile is APPEND-ONLY and read LATEST (its period is `recorded_during`,
//// transaction-time), so an edit is a temporal Change: close the row covering
//// `effective` by carving its [effective, NULL) tail off (DELETE FOR PORTION OF),
//// then open a new full row [effective, NULL) (INSERT). The pair runs in the
//// caller's single transaction — the SAME delete-then-insert shape as the engineer
//// detail facts, because the WITHOUT OVERLAPS PK cannot be an ON CONFLICT target.
//// On the first edit the close deletes 0 rows (a harmless no-op) and the open seeds
//// the first version.

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, UpdateClientProfile}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a client-details command: route it to its named operation, which does its
/// temporal write and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends this command here, so any other variant is a routing
/// bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    UpdateClientProfile(..) -> update_client_profile(conn, command)
    _ ->
      panic as "client_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record a new client profile from `effective` onward (Change on client_profile):
/// close the covering row at `effective`, open a new full [effective, NULL) row,
/// then return its journal event.
fn update_client_profile(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateClientProfile(client_id:, name:, effective:) = command
  use _ <- operation.try(sql.client_profile_close(conn, client_id, effective))
  use _ <- operation.try(sql.client_profile_open(
    conn,
    client_id,
    name,
    effective,
  ))
  Ok([
    Event(
      operation: "update_client_profile",
      summary: "Update profile for client "
        <> int.to_string(client_id)
        <> " ("
        <> name
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
