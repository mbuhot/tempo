//// Domain: the rate-card aggregate — a level's day rate versioned over time, the
//// FOR PORTION OF target. Every function takes the in-transaction connection and
//// does ONLY its temporal writes; `command.dispatch` owns the transaction and the
//// `event_log` row. No HTTP — never imports `wisp`.
////
//// The operations span two write patterns: `revise_rate_card` is a Change
//// (FOR PORTION OF … FROM effective TO NULL, re-rate from a date onward with the
//// `@>` guard leaving a scheduled-future version untouched); `adjust_rate_for_portion`
//// is the Surgical edit (FOR PORTION OF … FROM valid_from TO valid_to, splitting the
//// covering row into before/during/after).

import gleam/result
import gleam/time/calendar.{type Date}
import pog
import tempo/server/sql

/// Revise a level's day rate from `effective` onward (the Change pattern).
/// `FOR PORTION OF effective_during FROM effective TO NULL` lands the new rate on
/// [effective, row.upper) and re-inserts the [row.lower, effective) leftover at
/// the old rate; the `@> effective` guard confines it to the version in effect,
/// so a separately scheduled future rate is left untouched.
pub fn revise_rate_card(
  conn: pog.Connection,
  level: Int,
  day_rate: Float,
  effective: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.rate_card_revise(conn, effective, day_rate, level))
  Nil
}

/// Bump a level's day rate for a bounded window (the Surgical pattern).
/// `FOR PORTION OF effective_during FROM valid_from TO valid_to` changes only the
/// [valid_from, valid_to) sub-period of the covering version and carves off the
/// unchanged before/after remainders as their own rows.
pub fn adjust_rate_for_portion(
  conn: pog.Connection,
  level: Int,
  day_rate: Float,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.rate_card_for_portion_of(
    conn,
    valid_from,
    valid_to,
    day_rate,
    level,
  ))
  Nil
}
