//// Domain: the engineer aggregate — the engineer-identity lifecycle and the facts
//// contained by it (employment, role, the founding contact). `command.route`
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
//// implements as the Close/cascade (children capped first, then employment).

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{
  type EngineerCommand, EngineerCommand, OnboardEngineer, Promote,
  TerminateEmployment,
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
        payload: codecs.encode_command(EngineerCommand(command)),
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
        payload: codecs.encode_command(EngineerCommand(command)),
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
        payload: codecs.encode_command(EngineerCommand(command)),
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
