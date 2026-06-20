//// Domain: the rate-card aggregate — a level's day rate versioned over time.
//// `handle` routes each rate-card command to a named operation that returns the
//// `Fact`s it records; `command.dispatch` records them (through `repository`) and
//// persists the journal in ONE transaction. No HTTP — never imports `wisp`.
////
//// `revise_rate_card` re-rates from a date onward (`to: None`, the repository's
//// change); `adjust_rate_for_portion` is the bounded surgical edit (`to: Some`,
//// splitting the covering version into before/during/after).

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import pog
import shared/codecs
import shared/types.{type Command, AdjustRateForPortion, ReviseRateCard}
import tempo/server/fact.{type Fact}
import tempo/server/operation.{type OperationError}

/// Apply a rate-card-aggregate command: route it to its named operation, which
/// returns the facts it records. The dispatch `route` only ever sends rate-card
/// commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  _conn: pog.Connection,
  command: Command,
) -> Result(List(Fact), OperationError) {
  case command {
    ReviseRateCard(..) -> revise_rate_card(command)
    AdjustRateForPortion(..) -> adjust_rate_for_portion(command)
    _ ->
      panic as "rate_card.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Revise a level's day rate from `effective` onward, plus the journal entry.
fn revise_rate_card(command: Command) -> Result(List(Fact), OperationError) {
  let assert ReviseRateCard(level:, day_rate:, effective:) = command
  Ok([
    fact.RateCard(level:, day_rate:, from: effective, to: None),
    fact.CommandHandled(
      operation: "revise_rate_card",
      summary: "Revise L"
        <> int.to_string(level)
        <> " rate to "
        <> float.to_string(day_rate)
        <> " from "
        <> operation.iso(effective),
      payload: codecs.encode_command(command),
    ),
  ])
}

/// Adjust a level's day rate for a bounded window `[valid_from, valid_to)`, plus the
/// journal entry.
fn adjust_rate_for_portion(
  command: Command,
) -> Result(List(Fact), OperationError) {
  let assert AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) =
    command
  Ok([
    fact.RateCard(level:, day_rate:, from: valid_from, to: Some(valid_to)),
    fact.CommandHandled(
      operation: "adjust_rate_for_portion",
      summary: "Adjust L"
        <> int.to_string(level)
        <> " rate to "
        <> float.to_string(day_rate)
        <> " over "
        <> operation.span(valid_from, valid_to),
      payload: codecs.encode_command(command),
    ),
  ])
}
