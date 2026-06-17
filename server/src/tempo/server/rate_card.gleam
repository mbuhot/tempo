//// Domain: the rate-card aggregate — a level's day rate versioned over time, the
//// FOR PORTION OF target. `handle` routes each rate-card command to a named
//// operation that does ONLY its temporal write on the in-transaction connection and
//// classifies any database rejection; `command.dispatch` owns the transaction and
//// persists the journal event(s) `handle` returns. No HTTP — never imports `wisp`.
////
//// The operations span two write patterns: `revise_rate_card` is a Change
//// (FOR PORTION OF … FROM effective TO NULL, re-rate from a date onward with the
//// `@>` guard leaving a scheduled-future version untouched); `adjust_rate_for_portion`
//// is the Surgical edit (FOR PORTION OF … FROM valid_from TO valid_to, splitting the
//// covering row into before/during/after).

import gleam/float
import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, AdjustRateForPortion, ReviseRateCard}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a rate-card-aggregate command: route it to its named operation, then on
/// success return the journal event(s) it produced. The dispatch `route` only ever
/// sends rate-card commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    ReviseRateCard(level:, day_rate:, effective:) ->
      revise_rate_card(conn, level, day_rate, effective)
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      adjust_rate_for_portion(conn, level, day_rate, valid_from, valid_to)
    _ ->
      panic as "rate_card.handle: command not owned by this aggregate (dispatch bug)"
  }
  result.map(written, fn(_) { events(command) })
}

/// Revise a level's day rate from `effective` onward (Change, FOR PORTION OF … FROM
/// effective TO NULL); the `@>` guard leaves a scheduled-future version untouched.
fn revise_rate_card(
  conn: pog.Connection,
  level: Int,
  day_rate: Float,
  effective: Date,
) -> Result(Nil, OperationError) {
  operation.run(sql.rate_card_revise(conn, effective, day_rate, level))
}

/// Adjust a level's day rate for a bounded window (Surgical, FOR PORTION OF … FROM
/// valid_from TO valid_to), splitting the covering row into before/during/after.
fn adjust_rate_for_portion(
  conn: pog.Connection,
  level: Int,
  day_rate: Float,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, OperationError) {
  operation.run(sql.rate_card_for_portion_of(
    conn,
    valid_from,
    valid_to,
    day_rate,
    level,
  ))
}

/// The journal event(s) an applied rate-card command produces.
fn events(command: Command) -> List(Event) {
  case command {
    ReviseRateCard(level:, day_rate:, effective:) -> [
      Event(
        operation: "revise_rate_card",
        summary: "Revise L"
          <> int.to_string(level)
          <> " rate to "
          <> float.to_string(day_rate)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
    ]
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) -> [
      Event(
        operation: "adjust_rate_for_portion",
        summary: "Adjust L"
          <> int.to_string(level)
          <> " rate to "
          <> float.to_string(day_rate)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
    ]
    _ ->
      panic as "rate_card.events: command not owned by this aggregate (dispatch bug)"
  }
}
