//// Domain: the engineer aggregate — the engineer-identity lifecycle and the
//// facts contained by it (employment, role). `handle` matches the engineer
//// commands, does ONLY their temporal writes on the in-transaction connection,
//// classifies any database rejection, and returns the journal event(s) it
//// produced; `command.dispatch` owns the transaction and persists those events.
//// No HTTP — never imports `wisp`.
////
//// The operations span the four write patterns: `OnboardEngineer` is three
//// Asserts (identity → employment → role, each contained in the last by its
//// PERIOD FK); `Promote` is a Change (FOR PORTION OF … TO NULL); and
//// `TerminateEmployment` is the Close/cascade — children first
//// (allocation → leave → role → employment), the PERIOD FKs forcing the order and
//// verifying completeness.

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, OnboardEngineer, Promote, TerminateEmployment}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply an engineer-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection into an
/// `OperationError`, and on success return the single journal event it produced
/// (operation tag + human summary + the command re-encoded as payload). Only the
/// engineer commands reach here (the dispatch `route` guarantees it); any other
/// variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    OnboardEngineer(name:, level:, effective:) ->
      onboard_engineer(conn, name, level, effective)
    Promote(engineer_id:, level:, effective:) ->
      sql.engineer_role_change(conn, engineer_id, level, effective)
      |> result.replace(Nil)
    TerminateEmployment(engineer_id:, effective:) ->
      terminate_employment(conn, engineer_id, effective)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
}

/// The journal event(s) an applied engineer command produces: the operation tag,
/// a terse human summary, and the command re-encoded as the JSON payload.
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
    _ -> []
  }
}

/// Hire an engineer: mint the identity, open ongoing employment, then open the
/// initial role — all from `effective`, threaded through the minted id. Each
/// step is contained in the last by its PERIOD FK (role ⊂ employment), so an
/// out-of-order or dangling fact is rejected by the database.
fn onboard_engineer(
  conn: pog.Connection,
  name: String,
  level: Int,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use created <- result.try(sql.engineer_create(conn, name))
  let engineer_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  use _ <- result.try(sql.employment_open(conn, engineer_id, effective))
  use _ <- result.try(sql.engineer_role_open(
    conn,
    engineer_id,
    level,
    effective,
  ))
  Ok(Nil)
}

/// Terminate an engineer's employment from `effective`, capping every contained
/// fact (the Close/cascade pattern). The children are closed FIRST —
/// allocation → leave → role — then `employment` last; the PERIOD FKs both force
/// that order and verify completeness: a child left dangling past `effective`
/// (e.g. a timesheet outliving its allocation) rejects the whole transaction.
fn terminate_employment(
  conn: pog.Connection,
  engineer_id: Int,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.try(sql.allocation_close_all(conn, engineer_id, effective))
  use _ <- result.try(sql.leave_close_all(conn, engineer_id, effective))
  use _ <- result.try(sql.engineer_role_close_all(conn, engineer_id, effective))
  use _ <- result.map(sql.employment_close(conn, engineer_id, effective))
  Nil
}
