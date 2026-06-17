//// Domain: the engineer aggregate — the engineer-identity lifecycle and the
//// facts contained by it (employment, role). `handle` routes each engineer command
//// to a named operation that does ONLY its temporal writes on the in-transaction
//// connection and classifies any database rejection; `command.dispatch` owns the
//// transaction and persists the journal event(s) `handle` returns. No HTTP — never
//// imports `wisp`.
////
//// The operations span the four write patterns: `onboard_engineer` is three Asserts
//// (identity → employment → role, each contained in the last by its PERIOD FK);
//// `promote` is a Change (FOR PORTION OF … TO NULL); and `terminate_employment` is
//// the Close/cascade — children first (allocation → leave → role → employment), the
//// PERIOD FKs forcing the order and verifying completeness.

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, OnboardEngineer, Promote, TerminateEmployment}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engineer-aggregate command: route it to its named operation, then on
/// success return the journal event(s) it produced. The dispatch `route` only ever
/// sends engineer commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    OnboardEngineer(name:, level:, effective:) ->
      onboard_engineer(conn, name, level, effective)
    Promote(engineer_id:, level:, effective:) ->
      promote(conn, engineer_id, level, effective)
    TerminateEmployment(engineer_id:, effective:) ->
      terminate_employment(conn, engineer_id, effective)
    _ ->
      panic as "engineer.handle: command not owned by this aggregate (dispatch bug)"
  }
  result.map(written, fn(_) { events(command) })
}

/// Hire an engineer: mint the identity, open ongoing employment, then open the
/// initial role — all from `effective`, threaded through the minted id. Each step is
/// contained in the last by its PERIOD FK (role ⊂ employment), so an out-of-order or
/// dangling fact is rejected by the database.
fn onboard_engineer(
  conn: pog.Connection,
  name: String,
  level: Int,
  effective: Date,
) -> Result(Nil, OperationError) {
  use created <- operation.try(sql.engineer_create(conn, name))
  let engineer_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  use _ <- operation.try(sql.employment_open(conn, engineer_id, effective))
  use _ <- operation.try(sql.engineer_role_open(
    conn,
    engineer_id,
    level,
    effective,
  ))
  Ok(Nil)
}

/// Promote an engineer to a new level from `effective` onward (Change, FOR PORTION
/// OF held_during … TO NULL); the `@>` guard leaves a scheduled-future role untouched.
fn promote(
  conn: pog.Connection,
  engineer_id: Int,
  level: Int,
  effective: Date,
) -> Result(Nil, OperationError) {
  operation.run(sql.engineer_role_change(conn, engineer_id, level, effective))
}

/// Terminate an engineer's employment from `effective`, capping every contained fact
/// (Close/cascade). Children are closed FIRST — allocation → leave → role — then
/// `employment` last; the PERIOD FKs both force that order and verify completeness: a
/// child left dangling past `effective` rejects the whole transaction.
fn terminate_employment(
  conn: pog.Connection,
  engineer_id: Int,
  effective: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(sql.allocation_close_all(conn, engineer_id, effective))
  use _ <- operation.try(sql.leave_close_all(conn, engineer_id, effective))
  use _ <- operation.try(sql.engineer_role_close_all(
    conn,
    engineer_id,
    effective,
  ))
  use _ <- operation.try(sql.employment_close(conn, engineer_id, effective))
  Ok(Nil)
}

/// The journal event(s) an applied engineer command produces.
fn events(command: Command) -> List(Event) {
  case command {
    OnboardEngineer(name:, level:, effective:) -> [
      Event(
        operation: "onboard_engineer",
        summary: "Onboard "
          <> name
          <> " at L"
          <> int.to_string(level)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
    ]
    Promote(engineer_id:, level:, effective:) -> [
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
    ]
    TerminateEmployment(engineer_id:, effective:) -> [
      Event(
        operation: "terminate_employment",
        summary: "Terminate engineer "
          <> int.to_string(engineer_id)
          <> " employment from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
    ]
    _ ->
      panic as "engineer.events: command not owned by this aggregate (dispatch bug)"
  }
}
