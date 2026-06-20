//// Domain: the client-details aggregate — the single edit-grouped fact that hangs
//// off the client anchor (its profile, which is just the NAME). `handle` routes the
//// UpdateClientProfile command to a named operation that returns the `Fact`s it
//// records; `command.dispatch` records them (through `repository`) and persists the
//// journal in ONE transaction. No HTTP — never imports `wisp`.
////
//// The profile is recorded from `effective` onward; the repository makes that the
//// current version (a change, falling back to an open at client creation).

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, UpdateClientProfile}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}

/// Apply a client-details command: route it to its named operation, which returns
/// the facts it records. The dispatch `route` only ever sends this command here, so
/// any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    UpdateClientProfile(..) -> update_client_profile(command)
    _ ->
      panic as "client_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record a new client profile from `effective` onward, plus the journal entry.
fn update_client_profile(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert UpdateClientProfile(client_id:, name:, effective:) = command
  Ok([
    fact.ClientProfile(client_id:, name:, from: effective),
    fact.CommandHandled(
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
