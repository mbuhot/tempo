//// Domain: the engineer aggregate — the engineer-identity lifecycle and the
//// facts contained by it (employment, role). `handle` routes each engineer command
//// to a named operation that does ONLY its temporal writes on the in-transaction
//// connection and classifies any database rejection; `command.dispatch` owns the
//// transaction and persists the journal event(s) `handle` returns. No HTTP — never
//// imports `wisp`.
////
//// The operations span the four write patterns: `onboard_engineer` is a sequence of
//// Asserts (identity → employment → role → contact: role ⊂ employment by PERIOD FK,
//// and the founding engineer_contact row carrying the NAME — the ID-ONLY anchor no
//// longer stores it);
//// `promote` is a Change (FOR PORTION OF … TO NULL); and `terminate_employment` is
//// the Close/cascade — children first (allocation → leave → role → employment), the
//// PERIOD FKs forcing the order and verifying completeness.

import gleam/int
import pog
import shared/codecs
import shared/types.{type Command, OnboardEngineer, Promote, TerminateEmployment}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engineer-aggregate command: route it to its named operation, which does
/// its temporal writes and returns the journal event(s) it produced. The dispatch
/// `route` only ever sends engineer commands here, so any other variant is a routing
/// bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  case command {
    OnboardEngineer(..) -> onboard_engineer(conn, command)
    Promote(..) -> promote(conn, command)
    TerminateEmployment(..) -> terminate_employment(conn, command)
    _ ->
      panic as "engineer.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Hire an engineer: mint the identity, open ongoing employment, then open the
/// initial role — all from `effective`, threaded through the minted id — then return
/// its journal event carrying that id. Each step is contained in the last by its
/// PERIOD FK (role ⊂ employment), so an out-of-order or dangling fact is rejected by
/// the database.
fn onboard_engineer(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert OnboardEngineer(name:, level:, effective:) = command
  use created <- operation.try(sql.engineer_create(conn))
  let assert [row] = created.rows
  let engineer_id = row.id
  use _ <- operation.try(sql.employment_open(conn, engineer_id, effective))
  use _ <- operation.try(sql.engineer_role_open(
    conn,
    engineer_id,
    level,
    effective,
  ))
  // The NAME lives in engineer_contact now (the anchor is ID-ONLY); email/phone/
  // postal default to '' and are fillable later via UpdateContactDetails.
  use _ <- operation.try(sql.engineer_contact_open(
    conn,
    engineer_id,
    name,
    "",
    "",
    "",
    effective,
  ))
  Ok([
    Event(
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

/// Promote an engineer to a new level from `effective` onward (Change, FOR PORTION
/// OF held_during … TO NULL), then return its journal event; the `@>` guard leaves a
/// scheduled-future role untouched.
fn promote(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert Promote(engineer_id:, level:, effective:) = command
  use _ <- operation.try(sql.engineer_role_change(
    conn,
    engineer_id,
    level,
    effective,
  ))
  Ok([
    Event(
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

/// Terminate an engineer's employment from `effective`, capping every contained fact
/// (Close/cascade), then return its journal event. Children are closed FIRST —
/// allocation → leave → role — then `employment` last; the PERIOD FKs both force that
/// order and verify completeness: a child left dangling past `effective` rejects the
/// whole transaction.
fn terminate_employment(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let assert TerminateEmployment(engineer_id:, effective:) = command
  use _ <- operation.try(sql.allocation_close_all(conn, engineer_id, effective))
  use _ <- operation.try(sql.leave_close_all(conn, engineer_id, effective))
  use _ <- operation.try(sql.engineer_role_close_all(
    conn,
    engineer_id,
    effective,
  ))
  use _ <- operation.try(sql.employment_close(conn, engineer_id, effective))
  Ok([
    Event(
      operation: "terminate_employment",
      summary: "Terminate engineer "
        <> int.to_string(engineer_id)
        <> " employment from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}
