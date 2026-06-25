//// Domain: the client-details aggregate — the single edit-grouped fact that hangs
//// off the client anchor (its profile, which is just the NAME). `command.route`
//// destructures the UpdateClientProfile command and calls the operation here with
//// its already-narrowed fields; the operation returns the audit entry and the
//// `Fact`s it records, and `command.dispatch` hands both to `repository` in ONE
//// transaction. No HTTP — never imports `wisp`.
////
//// The profile is recorded from `effective` onward; the repository makes that the
//// current version (a change, falling back to an open at client creation).

import gleam/int
import gleam/time/calendar.{type Date}
import shared/client_details/command.{
  type ClientDetailsCommand, UpdateClientProfile,
}
import shared/command.{ClientDetailsCommand} as gateway
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Route a client-details command to its operation, returning the audit entry and
/// the facts it records. Exhaustive over `ClientDetailsCommand`.
pub fn route(
  command: ClientDetailsCommand,
) -> Result(Recorded, OperationError) {
  case command {
    UpdateClientProfile(client_id:, name:, effective:) ->
      update_client_profile(command, client_id:, name:, effective:)
  }
}

/// Record a new client profile from `effective` onward, with its journal entry.
pub fn update_client_profile(
  command: ClientDetailsCommand,
  client_id client_id: Int,
  name name: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "update_client_profile",
        summary: "Update profile for client "
          <> int.to_string(client_id)
          <> " ("
          <> name
          <> ") from "
          <> operation.iso(effective),
        payload: gateway.encode_command(ClientDetailsCommand(command)),
      ),
      facts: [
        fact.ClientProfile(
          client_id: fact.ClientId(client_id),
          name:,
          from: effective,
        ),
      ],
    ),
  )
}
