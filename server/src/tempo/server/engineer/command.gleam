//// Domain: the engineer aggregate — the engineer-identity lifecycle and the facts
//// contained by it (employment, role, the founding contact, and the three
//// edit-grouped facts: contact, banking, emergency). `command.route`
//// destructures each engineer command and calls the matching operation here with
//// its already-narrowed fields; the operation returns the `Fact`s it records, and
//// `command.dispatch` records them (through `repository`) and persists the journal
//// in ONE transaction. No HTTP — never imports `wisp`.
////
//// `onboard_engineer` reserves the engineer id (so it threads into every contained
//// fact without a read-back) then records the anchor, ongoing employment, the
//// opening role, and the founding contact (carrying the NAME — the anchor is
//// ID-ONLY). `promote` re-states the level from a date onward (the repository's
//// change). `terminate_employment` records `EngineerDeparted`, which the repository
//// implements as the Close/cascade (children capped first, then employment). Each
//// detail (contact/banking/emergency) is recorded from `effective` onward; the
//// repository makes that the current version (a change, falling back to an open
//// at onboard).

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{EngineerCommand} as gateway
import shared/engineer/command.{
  type EngineerCommand, OnboardEngineer, Promote, TerminateEmployment,
  UpdateBankingDetails, UpdateContactDetails, UpdateEmergencyContact,
}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}
import tempo/server/repository

/// Route an engineer command to its operation, returning the audit entry and the
/// facts it records. The `case` is exhaustive over `EngineerCommand`, so a new
/// engineer command with no arm is a compile error.
pub fn route(
  conn: pog.Connection,
  command: EngineerCommand,
) -> Result(Recorded, OperationError) {
  case command {
    OnboardEngineer(name:, level:, effective:) ->
      onboard_engineer(conn, command, name:, level:, effective:)
    Promote(engineer_id:, level:, effective:) ->
      promote(command, engineer_id:, level:, effective:)
    TerminateEmployment(engineer_id:, effective:) ->
      terminate_employment(command, engineer_id:, effective:)
    UpdateContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      effective:,
    ) ->
      update_contact_details(
        command,
        engineer_id:,
        name:,
        email:,
        phone:,
        postal_address:,
        effective:,
      )
    UpdateBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      effective:,
    ) ->
      update_banking_details(
        command,
        engineer_id:,
        bank:,
        branch:,
        account_no:,
        account_name:,
        effective:,
      )
    UpdateEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      effective:,
    ) ->
      update_emergency_contact(
        command,
        engineer_id:,
        relation:,
        name:,
        phone:,
        email:,
        effective:,
      )
  }
}

/// Hire an engineer: reserve the id, then record the anchor, ongoing employment, the
/// opening role, and the founding contact (email/phone/postal default to '' and are
/// fillable later via UpdateContactDetails), with the journal entry.
pub fn onboard_engineer(
  conn: pog.Connection,
  command: EngineerCommand,
  name name: String,
  level level: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  use engineer_id <- result.try(repository.create_engineer(conn))
  let fact.EngineerId(id) = engineer_id
  Ok(
    Recorded(
      entry: Event(
        operation: "onboard_engineer",
        summary: "Onboard "
          <> name
          <> " at L"
          <> int.to_string(level)
          <> " (engineer "
          <> int.to_string(id)
          <> ") from "
          <> operation.iso(effective),
        payload: gateway.encode_command(EngineerCommand(command)),
      ),
      facts: [
        fact.EngineerEmployed(engineer_id:, from: effective),
        fact.EngineerAtLevel(engineer_id:, level:, from: effective),
        fact.EngineerContactDetails(
          engineer_id:,
          name:,
          email: "",
          phone: "",
          postal_address: "",
          from: effective,
        ),
      ],
    ),
  )
}

/// Promote an engineer to a new level from `effective` onward, with the journal
/// entry.
pub fn promote(
  command: EngineerCommand,
  engineer_id engineer_id: Int,
  level level: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "promote",
        summary: "Promote engineer "
          <> int.to_string(engineer_id)
          <> " to L"
          <> int.to_string(level)
          <> " from "
          <> operation.iso(effective),
        payload: gateway.encode_command(EngineerCommand(command)),
      ),
      facts: [
        fact.EngineerAtLevel(
          engineer_id: fact.EngineerId(engineer_id),
          level:,
          from: effective,
        ),
      ],
    ),
  )
}

/// Terminate an engineer's employment from `effective`, with the journal entry. The
/// `EngineerDeparted` fact caps employment and cascades the cap to every contained
/// fact (allocation, leave, role) in the repository.
pub fn terminate_employment(
  command: EngineerCommand,
  engineer_id engineer_id: Int,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "terminate_employment",
        summary: "Terminate engineer "
          <> int.to_string(engineer_id)
          <> " employment from "
          <> operation.iso(effective),
        payload: gateway.encode_command(EngineerCommand(command)),
      ),
      facts: [
        fact.EngineerDeparted(
          engineer_id: fact.EngineerId(engineer_id),
          from: effective,
        ),
      ],
    ),
  )
}

/// Record new contact details from `effective` onward, with its journal entry.
pub fn update_contact_details(
  command: EngineerCommand,
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
        payload: gateway.encode_command(EngineerCommand(command)),
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
  command: EngineerCommand,
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
        payload: gateway.encode_command(EngineerCommand(command)),
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
  command: EngineerCommand,
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
        payload: gateway.encode_command(EngineerCommand(command)),
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
