//// Domain: the engineer-details aggregate — the three edit-grouped facts that hang
//// off the engineer anchor (contact, banking, emergency). `command.route`
//// destructures each Update* command and calls the matching operation here with its
//// already-narrowed fields; the operation returns the audit entry and the `Fact`s it
//// records, and `command.dispatch` hands both to `repository` in ONE transaction. No
//// HTTP — never imports `wisp`.
////
//// Each detail is recorded from `effective` onward; the repository makes that the
//// current version (a change, falling back to an open at onboard).

import gleam/int
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Record new contact details from `effective` onward, with its journal entry.
pub fn update_contact_details(
  command: Command,
  engineer_id engineer_id: Int,
  name name: String,
  email email: String,
  phone phone: String,
  postal_address postal_address: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "update_contact_details",
        summary: "Update contact for engineer "
          <> int.to_string(engineer_id)
          <> " ("
          <> name
          <> ") from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerContactDetails(
          engineer_id: fact.EngineerId(engineer_id),
          name:,
          email:,
          phone:,
          postal_address:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Record new banking details from `effective` onward, with its journal entry.
pub fn update_banking_details(
  command: Command,
  engineer_id engineer_id: Int,
  bank bank: String,
  branch branch: String,
  account_no account_no: String,
  account_name account_name: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "update_banking_details",
        summary: "Update banking for engineer "
          <> int.to_string(engineer_id)
          <> " ("
          <> bank
          <> ") from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerBankingDetails(
          engineer_id: fact.EngineerId(engineer_id),
          bank:,
          branch:,
          account_no:,
          account_name:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Record a new emergency contact from `effective` onward, with its journal entry.
pub fn update_emergency_contact(
  command: Command,
  engineer_id engineer_id: Int,
  relation relation: String,
  name name: String,
  phone phone: String,
  email email: String,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
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
      facts: [
        fact.EngineerEmergencyContact(
          engineer_id: fact.EngineerId(engineer_id),
          relation:,
          name:,
          phone:,
          email:,
          from: effective,
        ),
      ],
    ),
  )
}
