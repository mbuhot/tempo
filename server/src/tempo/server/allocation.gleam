//// Domain: the allocation aggregate — an engineer's fractional assignment to a
//// project over time. Every function takes the in-transaction connection and does
//// ONLY its temporal writes; `command.dispatch` owns the transaction and the
//// `event_log` row. No HTTP — never imports `wisp`.
////
//// The operations span three of the four write patterns: `assign_to_project` is
//// an Assert over [valid_from, valid_to) (the allocation is contained by both
//// employment and project via PERIOD FKs); `change_allocation_fraction` is a Change
//// (FOR PORTION OF … TO NULL, re-fraction from a date onward, scheduled-future
//// versions untouched); `roll_off` is a Close (DELETE … FOR PORTION OF, capping
//// one allocation from a date).

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import tempo/server/sql

/// Allocate an engineer to a project at `fraction` over [valid_from, valid_to)
/// (the Assert pattern). The PERIOD FKs to employment and project are the
/// backstop — an allocation not contained by both a live employment and an active
/// project is rejected — and the WITHOUT OVERLAPS PK rejects a second overlapping
/// allocation for the same engineer+project.
pub fn assign_to_project(
  conn: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  fraction: Float,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.allocation_assign(
    conn,
    engineer_id,
    project_id,
    valid_from,
    fraction,
    valid_to,
  ))
  Nil
}

/// Re-fraction an engineer's allocation on a project from `effective` onward (the
/// Change pattern). `FOR PORTION OF allocated_during FROM effective TO NULL` lands
/// the new fraction on [effective, row.upper) and re-inserts the
/// [row.lower, effective) leftover at the old fraction; the `@> effective` guard
/// confines it to the version in effect, leaving a scheduled-future version untouched.
pub fn change_allocation_fraction(
  conn: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  fraction: Float,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.allocation_change_fraction(
    conn,
    engineer_id,
    project_id,
    effective,
    fraction,
  ))
  Nil
}

/// Roll an engineer off a project from `effective` (the Close pattern).
/// `DELETE … FOR PORTION OF allocated_during FROM effective TO NULL` caps a
/// spanning allocation to [row.lower, effective) (PG re-inserts the before-leftover)
/// and drops a fully-future one outright.
pub fn roll_off(
  conn: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.allocation_close(
    conn,
    engineer_id,
    project_id,
    effective,
  ))
  Nil
}
