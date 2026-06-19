//// Domain: the client-details aggregate — the single edit-grouped fact that hangs
//// off the client anchor (its profile, which is just the NAME). `handle` routes the
//// UpdateClientProfile command to a named operation that does ONLY its temporal
//// write on the in-transaction connection and classifies any database rejection;
//// `command.dispatch` owns the transaction and persists the journal event(s)
//// `handle` returns. No HTTP — never imports `wisp`.
////
//// client_profile is APPEND-ONLY and read LATEST (its period is `recorded_during`,
//// transaction-time), so an edit is a temporal Change in ONE statement — a
//// FOR PORTION OF UPDATE (like rate_card/salary): it re-sets the [effective, NULL)
//// portion of the row covering `effective`, and PG carves off the unchanged
//// [start, effective) remainder as its own row. The founding row is opened at
//// client creation (sign_contract), so the covering row always exists.

import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, UpdateClientProfile}
import tempo/server/fact
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/repository

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
/// re-set the covering row's [effective, NULL) portion in one FOR PORTION OF
/// UPDATE, then return its journal event.
fn update_client_profile(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateClientProfile(client_id:, name:, effective:) = command
  use _ <- result.try(
    repository.record_facts(conn, [
      fact.ClientProfile(client_id:, name:, effective:),
    ]),
  )
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
