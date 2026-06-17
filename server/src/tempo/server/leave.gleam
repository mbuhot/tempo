//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. Every function takes the in-transaction
//// connection and does ONLY its temporal writes; `command.dispatch` owns the
//// transaction and the `event_log` row. No HTTP — never imports `wisp`.
////
//// `take_leave` is an Assert (write pattern 1): a plain insert of a bounded leave
//// fact. The `leave_within_employment` PERIOD FK is the backstop — leave outside
//// the engineer's employment is rejected by the database.

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import tempo/server/sql

/// Put an engineer on leave of `kind` over [valid_from, valid_to) (the Assert
/// pattern). The `leave_within_employment` PERIOD FK is the backstop — leave that
/// falls outside the engineer's employment is rejected by the database.
pub fn take_leave(
  conn: pog.Connection,
  engineer_id: Int,
  kind: String,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.leave_take(
    conn,
    engineer_id,
    kind,
    valid_from,
    valid_to,
  ))
  Nil
}
