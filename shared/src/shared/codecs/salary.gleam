//// JSON codec for `SalaryCommand` — the salary aggregate's slice of the command
//// wire contract (what we pay a level over time, the cost analogue of `rate_card`).
//// `encode` tags the variant by its `op`; `decoder` returns the field decoder for
//// an `op` this aggregate owns (`Error(Nil)` for any other), so the top-level
//// `codecs.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date, lenient_float_decoder}
import shared/types.{type SalaryCommand, SetSalary}

/// Encode a `SalaryCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: SalaryCommand) -> Json {
  case command {
    SetSalary(level:, monthly_salary:, effective:) ->
      json.object([
        #("op", json.string("set_salary")),
        #("level", json.int(level)),
        #("monthly_salary", json.float(monthly_salary)),
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
        use monthly_salary <- decode.field(
          "monthly_salary",
          lenient_float_decoder(),
        )
        use effective <- decode.field("effective", date_decoder())
        decode.success(SetSalary(level:, monthly_salary:, effective:))
      })
    _ -> Error(Nil)
  }
}
