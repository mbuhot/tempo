//// The payroll read models and their JSON codecs: the materialized-run
//// `PayrollRunInfo`, one engineer's `PayrollLine` (live preview vs frozen paid),
//// and the month's `Payroll` envelope. Pure Gleam, no target-specific deps, so
//// they round-trip on both ends of the JSON-over-HTTP boundary. Dates serialise
//// as ISO-8601 "YYYY-MM-DD" strings; money decodes leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire

/// Identifies the materialized payroll run for a month (FR-F5/FR-F6) once it
/// exists; absent from the `Payroll` envelope until `RunPayroll` has been done.
pub type PayrollRunInfo {
  PayrollRunInfo(run_id: Int)
}

/// One engineer's line in the month's payroll panel. `preview_amount`/
/// `preview_days` are the LIVE recompute over current facts (always present).
/// `paid_amount`/`paid_days` are the MATERIALIZED values frozen at run time
/// (`None` until a run exists). Variance Δ = preview_amount - paid_amount.
pub type PayrollLine {
  PayrollLine(
    engineer: String,
    preview_amount: Money,
    preview_days: Float,
    paid_amount: Option(Money),
    paid_days: Option(Float),
  )
}

/// A month's payroll read model (`GET /api/payroll?period=`): the
/// `period_from`..`period_to` month, the materialized `run` (`None` until
/// `RunPayroll`), and one `PayrollLine` per employed engineer.
pub type Payroll {
  Payroll(
    period_from: Date,
    period_to: Date,
    run: Option(PayrollRunInfo),
    lines: List(PayrollLine),
  )
}

/// Encode a `PayrollLine` (live preview plus the materialized paid values) as a
/// JSON object. `paid_amount`/`paid_days` are `null` until a run exists.
pub fn encode_payroll_line(line: PayrollLine) -> Json {
  let PayrollLine(
    engineer:,
    preview_amount:,
    preview_days:,
    paid_amount:,
    paid_days:,
  ) = line
  json.object([
    #("engineer", json.string(engineer)),
    #("preview_amount", money.encode(preview_amount)),
    #("preview_days", json.float(preview_days)),
    #("paid_amount", json.nullable(paid_amount, money.encode)),
    #("paid_days", json.nullable(paid_days, json.float)),
  ])
}

/// Decode a `PayrollLine` from a JSON object.
pub fn payroll_line_decoder() -> Decoder(PayrollLine) {
  use engineer <- decode.field("engineer", decode.string)
  use preview_amount <- decode.field("preview_amount", money.decoder())
  use preview_days <- decode.field("preview_days", wire.lenient_float_decoder())
  use paid_amount <- decode.field(
    "paid_amount",
    decode.optional(money.decoder()),
  )
  use paid_days <- decode.field(
    "paid_days",
    decode.optional(wire.lenient_float_decoder()),
  )
  decode.success(PayrollLine(
    engineer:,
    preview_amount:,
    preview_days:,
    paid_amount:,
    paid_days:,
  ))
}

/// Encode a `PayrollRunInfo` (the materialized run's id) as a JSON object.
pub fn encode_payroll_run_info(run: PayrollRunInfo) -> Json {
  let PayrollRunInfo(run_id:) = run
  json.object([#("run_id", json.int(run_id))])
}

/// Decode a `PayrollRunInfo` from a JSON object.
pub fn payroll_run_info_decoder() -> Decoder(PayrollRunInfo) {
  use run_id <- decode.field("run_id", decode.int)
  decode.success(PayrollRunInfo(run_id:))
}

/// Encode a `Payroll` month read model (period, optional run, lines) to JSON.
pub fn encode_payroll(payroll: Payroll) -> Json {
  let Payroll(period_from:, period_to:, run:, lines:) = payroll
  json.object([
    #("period_from", wire.encode_date(period_from)),
    #("period_to", wire.encode_date(period_to)),
    #("run", json.nullable(run, encode_payroll_run_info)),
    #("lines", json.array(lines, encode_payroll_line)),
  ])
}

/// Decode a `Payroll` month read model from JSON.
pub fn payroll_decoder() -> Decoder(Payroll) {
  use period_from <- decode.field("period_from", wire.date_decoder())
  use period_to <- decode.field("period_to", wire.date_decoder())
  use run <- decode.field("run", decode.optional(payroll_run_info_decoder()))
  use lines <- decode.field("lines", decode.list(payroll_line_decoder()))
  decode.success(Payroll(period_from:, period_to:, run:, lines:))
}
