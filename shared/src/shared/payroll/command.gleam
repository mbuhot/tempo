//// The payroll aggregate's write command type and its JSON codec (a per-month run).
//// `encode` tags the variant by its `op`; `decoder` returns the field decoder for
//// an `op` this aggregate owns (`Error(Nil)` for any other), so
//// `shared/command.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type PayrollCommand {
  /// Run payroll for a month, computing one prorated `payroll_line` per employed
  /// engineer (split by role so a mid-month promotion blends salaries).
  RunPayroll(period_from: Date, period_to: Date)
}

/// Encode a `PayrollCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: PayrollCommand) -> Json {
  case command {
    RunPayroll(period_from:, period_to:) ->
      json.object([
        #("op", json.string("run_payroll")),
        #("period_from", encode_date(period_from)),
        #("period_to", encode_date(period_to)),
      ])
  }
}

/// The field decoder for a payroll `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(PayrollCommand), Nil) {
  case op {
    "run_payroll" ->
      Ok({
        use period_from <- decode.field("period_from", date_decoder())
        use period_to <- decode.field("period_to", date_decoder())
        decode.success(RunPayroll(period_from:, period_to:))
      })
    _ -> Error(Nil)
  }
}
