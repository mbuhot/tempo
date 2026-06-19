//// Domain: the engineer-details aggregate — the three edit-grouped facts that
//// hang off the engineer anchor (contact, banking, emergency). `handle` routes
//// each Update* command to a named operation that does ONLY its temporal write on
//// the in-transaction connection and classifies any database rejection;
//// `command.dispatch` owns the transaction and persists the journal event(s)
//// `handle` returns. No HTTP — never imports `wisp`.
////
//// These facts are APPEND-ONLY and read LATEST (their period is `recorded_during`,
//// transaction-time), so an edit is a temporal Change: close the row covering
//// `effective` by carving its [effective, NULL) tail off (DELETE FOR PORTION OF),
//// then open a new full row [effective, NULL) (INSERT). The pair runs in the
//// caller's single transaction — the SAME delete-then-insert shape as the
//// timesheet upsert, because the WITHOUT OVERLAPS PK cannot be an ON CONFLICT
//// target. On the first edit the close deletes 0 rows (a harmless no-op) and the
//// open seeds the first version.

import gleam/int
import pog
import shared/codecs
import shared/types.{
  type Command, UpdateBankingDetails, UpdateContactDetails,
  UpdateEmergencyContact,
}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engineer-details command: route it to its named operation, which does
/// its temporal write and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends these three commands here, so any other variant is a
/// routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    UpdateContactDetails(..) -> update_contact_details(conn, command)
    UpdateBankingDetails(..) -> update_banking_details(conn, command)
    UpdateEmergencyContact(..) -> update_emergency_contact(conn, command)
    _ ->
      panic as "engineer_details.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record new contact details from `effective` onward (Change on engineer_contact):
/// close the covering row at `effective`, open a new full [effective, NULL) row,
/// then return its journal event.
fn update_contact_details(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateContactDetails(
    engineer_id:,
    name:,
    email:,
    phone:,
    postal_address:,
    effective:,
  ) = command
  use _ <- operation.try(sql.engineer_contact_close(
    conn,
    engineer_id,
    effective,
  ))
  use _ <- operation.try(sql.engineer_contact_open(
    conn,
    engineer_id,
    name,
    email,
    phone,
    postal_address,
    effective,
  ))
  Ok([
    Event(
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

/// Record new banking details from `effective` onward (Change on engineer_banking):
/// close the covering row at `effective`, open a new full [effective, NULL) row,
/// then return its journal event.
fn update_banking_details(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateBankingDetails(
    engineer_id:,
    bank:,
    branch:,
    account_no:,
    account_name:,
    effective:,
  ) = command
  use _ <- operation.try(sql.engineer_banking_close(
    conn,
    engineer_id,
    effective,
  ))
  use _ <- operation.try(sql.engineer_banking_open(
    conn,
    engineer_id,
    bank,
    branch,
    account_no,
    account_name,
    effective,
  ))
  Ok([
    Event(
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

/// Record a new emergency contact from `effective` onward (Change on
/// engineer_emergency): close the covering row at `effective`, open a new full
/// [effective, NULL) row, then return its journal event.
fn update_emergency_contact(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert UpdateEmergencyContact(
    engineer_id:,
    relation:,
    name:,
    phone:,
    email:,
    effective:,
  ) = command
  use _ <- operation.try(sql.engineer_emergency_close(
    conn,
    engineer_id,
    effective,
  ))
  use _ <- operation.try(sql.engineer_emergency_open(
    conn,
    engineer_id,
    relation,
    name,
    phone,
    email,
    effective,
  ))
  Ok([
    Event(
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
