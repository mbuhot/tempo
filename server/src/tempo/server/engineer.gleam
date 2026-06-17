//// Domain: the engineer aggregate — the engineer-identity lifecycle and the
//// facts contained by it (employment, role). Every function takes the
//// in-transaction connection and does ONLY its temporal writes; `command.dispatch`
//// owns the transaction and the `event_log` row. No HTTP — never imports `wisp`.
////
//// The operations span the four write patterns: `onboard_engineer` is three
//// Asserts (identity → employment → role, each contained in the last by its
//// PERIOD FK); `promote` is a Change (FOR PORTION OF … TO NULL); and
//// `terminate_employment` is the Close/cascade — children first
//// (allocation → leave → role → employment), the PERIOD FKs forcing the order and
//// verifying completeness.

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import tempo/server/sql

/// Hire an engineer: mint the identity, open ongoing employment, then open the
/// initial role — all from `effective`, threaded through the minted id. Each
/// step is contained in the last by its PERIOD FK (role ⊂ employment), so an
/// out-of-order or dangling fact is rejected by the database.
pub fn onboard_engineer(
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

/// Promote an engineer to a new level effective from a date (the Change pattern).
/// `FOR PORTION OF held_during FROM effective TO NULL` lands the new level on
/// [effective, row.upper) and re-inserts the [row.lower, effective) leftover at
/// the old level; the `@> effective` guard confines it to the version in effect,
/// so a separately scheduled future role is left untouched.
pub fn promote(
  conn: pog.Connection,
  engineer_id: Int,
  level: Int,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.engineer_role_change(
    conn,
    engineer_id,
    level,
    effective,
  ))
  Nil
}

/// Terminate an engineer's employment from `effective`, capping every contained
/// fact (the Close/cascade pattern). The children are closed FIRST —
/// allocation → leave → role — then `employment` last; the PERIOD FKs both force
/// that order and verify completeness: a child left dangling past `effective`
/// (e.g. a timesheet outliving its allocation) rejects the whole transaction.
pub fn terminate_employment(
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
