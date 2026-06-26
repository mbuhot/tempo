//// The salary aggregate's write command type and its JSON codec (what we pay a level
//// over time, the cost analogue of `rate_card`). `encode` tags the variant by its
//// `op`; `decoder` returns the field decoder for an `op` this aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire.{date_decoder, encode_date}

pub type SalaryCommand {
  /// Publish a new monthly salary for a level effective from a date (the cost
  /// analogue of `ReviseRateCard`, via `FOR PORTION OF` on `salary`).
  SetSalary(level: Int, monthly_salary: Money, effective: Date)
}

/// Encode a `SalaryCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: SalaryCommand) -> Json {
  case command {
    SetSalary(level:, monthly_salary:, effective:) ->
      json.object([
        #("op", json.string("set_salary")),
        #("level", json.int(level)),
        #("monthly_salary", money.encode(monthly_salary)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a salary `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(SalaryCommand), Nil) {
  case op {
    "set_salary" ->
      Ok({
        use level <- decode.field("level", decode.int)
        use monthly_salary <- decode.field("monthly_salary", money.decoder())
        use effective <- decode.field("effective", date_decoder())
        decode.success(SetSalary(level:, monthly_salary:, effective:))
      })
    _ -> Error(Nil)
  }
}
