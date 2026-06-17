//// Domain: the rate-card aggregate — a level's day rate versioned over time, the
//// FOR PORTION OF target. `handle` matches the rate-card commands, does ONLY their
//// temporal writes on the in-transaction connection, classifies any database
//// rejection, and returns the journal event(s) it produced; `command.dispatch`
//// owns the transaction and persists those events. No HTTP — never imports `wisp`.
////
//// The operations span two write patterns: `ReviseRateCard` is a Change
//// (FOR PORTION OF … FROM effective TO NULL, re-rate from a date onward with the
//// `@>` guard leaving a scheduled-future version untouched); `AdjustRateForPortion`
//// is the Surgical edit (FOR PORTION OF … FROM valid_from TO valid_to, splitting the
//// covering row into before/during/after).

import gleam/float
import gleam/int
import gleam/result
import pog
import shared/codecs
import shared/types.{type Command, AdjustRateForPortion, ReviseRateCard}
import tempo/server/operation.{type Event, type OperationError, Event}
import tempo/server/sql

/// Apply a rate-card-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection, and on success
/// return the single journal event it produced. Only the rate-card commands reach
/// here (the dispatch `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    ReviseRateCard(level:, day_rate:, effective:) ->
      sql.rate_card_revise(conn, effective, day_rate, level)
      |> result.replace(Nil)
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      sql.rate_card_for_portion_of(conn, valid_from, valid_to, day_rate, level)
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
  case written {
    Error(query_error) -> Error(operation.classify(query_error))
    Ok(Nil) -> Ok(events(command))
  }
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
    _ -> []
  }
}
