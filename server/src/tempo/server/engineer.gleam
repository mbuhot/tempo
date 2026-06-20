//// Domain: the engineer aggregate — the engineer-identity lifecycle and the facts
//// contained by it (employment, role, the founding contact). `handle` routes each
//// engineer command to a named operation that returns the `Fact`s it records;
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
import pog
import shared/codecs
import shared/types.{type Command, OnboardEngineer, Promote, TerminateEmployment}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}
import tempo/server/repository

/// Apply an engineer-aggregate command: route it to its named operation, which
/// returns the facts it records. The dispatch `route` only ever sends engineer
/// commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    OnboardEngineer(..) -> onboard_engineer(conn, command)
    Promote(..) -> promote(command)
    TerminateEmployment(..) -> terminate_employment(command)
    _ ->
      panic as "engineer.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Hire an engineer: reserve the id, then record the anchor, ongoing employment, the
/// opening role, and the founding contact (email/phone/postal default to '' and are
/// fillable later via UpdateContactDetails), plus the journal entry.
fn onboard_engineer(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert OnboardEngineer(name:, level:, effective:) = command
  use engineer_id <- result.try(repository.next_id(conn, repository.Engineers))
  Ok([
    fact.Engineer(id: engineer_id),
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
    fact.CommandHandled(
      operation: "onboard_engineer",
      summary: "Onboard "
        <> name
        <> " at L"
        <> int.to_string(level)
        <> " (engineer "
        <> int.to_string(engineer_id)
        <> ") from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Promote an engineer to a new level from `effective` onward, plus the journal
/// entry.
fn promote(command: Command) -> Result(List(Fact), OperationError) {
  let assert Promote(engineer_id:, level:, effective:) = command
  Ok([
    fact.EngineerAtLevel(engineer_id:, level:, from: effective),
    fact.CommandHandled(
      operation: "promote",
      summary: "Promote engineer "
        <> int.to_string(engineer_id)
        <> " to L"
        <> int.to_string(level)
        <> " from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Terminate an engineer's employment from `effective`, plus the journal entry. The
/// `EngineerDeparted` fact caps employment and cascades the cap to every contained
/// fact (allocation, leave, role) in the repository.
fn terminate_employment(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert TerminateEmployment(engineer_id:, effective:) = command
  Ok([
    fact.EngineerDeparted(engineer_id:, from: effective),
    fact.CommandHandled(
      operation: "terminate_employment",
      summary: "Terminate engineer "
        <> int.to_string(engineer_id)
        <> " employment from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
