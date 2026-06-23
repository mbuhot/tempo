//// Domain: the rate-card aggregate — a level's day rate versioned over time.
//// `command.route` destructures each rate-card command and calls the matching
//// operation here with its already-narrowed fields; the operation returns the
//// `Fact`s it records, and `command.dispatch` records them (through `repository`)
//// and persists the journal in ONE transaction. No HTTP — never imports `wisp`.
////
//// `revise_rate_card` re-rates from a date onward (`to: None`, the repository's
//// change); `adjust_rate_for_portion` is the bounded surgical edit (`to: Some`,
//// splitting the covering version into before/during/after).

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type Command}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event}

/// Revise a level's day rate from `effective` onward, with the journal entry.
pub fn revise_rate_card(
  command: Command,
  level level: Int,
  day_rate day_rate: Float,
  effective effective: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "revise_rate_card",
        summary: "Revise L"
          <> int.to_string(level)
          <> " rate to "
          <> float.to_string(day_rate)
          <> " from "
          <> operation.iso(effective),
        payload: codecs.encode_command(command),
      ),
      facts: [fact.RateCard(level:, day_rate:, from: effective, to: None)],
    ),
  )
}

/// Adjust a level's day rate for a bounded window `[valid_from, valid_to)`, with the
/// journal entry.
pub fn adjust_rate_for_portion(
  command: Command,
  level level: Int,
  day_rate day_rate: Float,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
  Ok(
    Recorded(
      entry: Event(
        operation: "adjust_rate_for_portion",
        summary: "Adjust L"
          <> int.to_string(level)
          <> " rate to "
          <> float.to_string(day_rate)
          <> " over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.RateCard(level:, day_rate:, from: valid_from, to: Some(valid_to)),
      ],
    ),
  )
}
