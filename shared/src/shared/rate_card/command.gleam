//// The rate-card aggregate's write command type and its JSON codec (a level's day
//// rate versioned over time: the open-ended revise and the bounded surgical adjust).
//// `encode` tags each variant by its `op`; `decoder` returns the field decoder for
//// an `op` this aggregate owns (`Error(Nil)` for any other), so
//// `shared/command.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire.{date_decoder, encode_date}

pub type RateCardCommand {
  /// Publish a new day rate for a level effective from a date.
  ReviseRateCard(level: Int, day_rate: Money, effective: Date)
  /// Bump a level's day rate for a bounded window, splitting the rate-card row
  /// into before/during/after.
  AdjustRateForPortion(
    level: Int,
    day_rate: Money,
    valid_from: Date,
    valid_to: Date,
  )
}

/// Encode a `RateCardCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: RateCardCommand) -> Json {
  case command {
    ReviseRateCard(level:, day_rate:, effective:) ->
      json.object([
        #("op", json.string("revise_rate_card")),
        #("level", json.int(level)),
        #("day_rate", money.encode(day_rate)),
        #("effective", encode_date(effective)),
      ])
    AdjustRateForPortion(level:, day_rate:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("adjust_rate_for_portion")),
        #("level", json.int(level)),
        #("day_rate", money.encode(day_rate)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
  }
}

/// The field decoder for a rate-card `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(RateCardCommand), Nil) {
  case op {
    "revise_rate_card" ->
      Ok({
        use level <- decode.field("level", decode.int)
        use day_rate <- decode.field("day_rate", money.decoder())
        use effective <- decode.field("effective", date_decoder())
        decode.success(ReviseRateCard(level:, day_rate:, effective:))
      })
    "adjust_rate_for_portion" ->
      Ok({
        use level <- decode.field("level", decode.int)
        use day_rate <- decode.field("day_rate", money.decoder())
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(AdjustRateForPortion(
          level:,
          day_rate:,
          valid_from:,
          valid_to:,
        ))
      })
    _ -> Error(Nil)
  }
}
