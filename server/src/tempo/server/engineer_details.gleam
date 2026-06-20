//// Domain: the engineer-details aggregate — the three edit-grouped facts that hang
//// off the engineer anchor (contact, banking, emergency). `handle` routes each
//// Update* command to a named operation that returns the `Fact`s it records;
//// `command.dispatch` records them (through `repository`) and persists the journal
//// in ONE transaction. No HTTP — never imports `wisp`.
////
//// Each detail is recorded from `effective` onward; the repository makes that the
//// current version (a change, falling back to an open at onboard).

import gleam/int
import pog
import shared/codecs
import shared/types.{
  type Command, UpdateBankingDetails, UpdateContactDetails,
  UpdateEmergencyContact,
}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}

/// Apply an engineer-details command: route it to its named operation, which returns
/// the facts it records. The dispatch `route` only ever sends these three commands
/// here, so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    UpdateContactDetails(..) -> update_contact_details(command)
    UpdateBankingDetails(..) -> update_banking_details(command)
    UpdateEmergencyContact(..) -> update_emergency_contact(command)
    _ ->
      panic as "engineer_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record new contact details from `effective` onward, plus the journal entry.
fn update_contact_details(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert UpdateContactDetails(
    engineer_id:,
    name:,
    email:,
    phone:,
    postal_address:,
    effective:,
  ) = command
  Ok([
    fact.EngineerContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      from: effective,
    ),
    fact.CommandHandled(
      operation: "update_contact_details",
      summary: "Update contact for engineer "
        <> int.to_string(engineer_id)
        <> " ("
        <> name
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Record new banking details from `effective` onward, plus the journal entry.
fn update_banking_details(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert UpdateBankingDetails(
    engineer_id:,
    bank:,
    branch:,
    account_no:,
    account_name:,
    effective:,
  ) = command
  Ok([
    fact.EngineerBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      from: effective,
    ),
    fact.CommandHandled(
      operation: "update_banking_details",
      summary: "Update banking for engineer "
        <> int.to_string(engineer_id)
        <> " ("
        <> bank
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Record a new emergency contact from `effective` onward, plus the journal entry.
fn update_emergency_contact(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert UpdateEmergencyContact(
    engineer_id:,
    relation:,
    name:,
    phone:,
    email:,
    effective:,
  ) = command
  Ok([
    fact.EngineerEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      from: effective,
    ),
    fact.CommandHandled(
      operation: "update_emergency_contact",
      summary: "Update emergency contact for engineer "
        <> int.to_string(engineer_id)
        <> " ("
        <> relation
        <> ": "
        <> name
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
