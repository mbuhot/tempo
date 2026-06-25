//// The settings read models and their JSON codecs: the as-of `RateCardRow`,
//// `SalaryRow`, and `LeavePolicyRow` lines and the whole `Settings` envelope.
//// Pure Gleam, no target-specific deps, so they round-trip on both ends of the
//// JSON-over-HTTP boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings;
//// money fields decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire

/// One row of the rate card on the settings read model: the current `day_rate`
/// (charge rate) for a `level` as-of the date.
pub type RateCardRow {
  RateCardRow(level: Int, day_rate: Float)
}

/// One row of the salary table on the settings read model: the current
/// `monthly_salary` (cost) for a `level` as-of the date.
pub type SalaryRow {
  SalaryRow(level: Int, monthly_salary: Float)
}

/// One row of the leave policy on the settings read model: the `days_per_year`
/// allowance for a `(kind, level)` pair as-of the date. A `(kind, level)` with no
/// policy row is unlimited (absent from the list).
pub type LeavePolicyRow {
  LeavePolicyRow(kind: String, level: Int, days_per_year: Float)
}

/// The settings read model (`GET /api/settings?as_of=`): the `date` and the
/// current `rate_card`, `salaries`, and `leave_policy` lists as-of that date.
pub type Settings {
  Settings(
    date: Date,
    rate_card: List(RateCardRow),
    salaries: List(SalaryRow),
    leave_policy: List(LeavePolicyRow),
  )
}

/// Encode a `RateCardRow` (one rate-card row) as a JSON object.
pub fn encode_rate_card_row(rate: RateCardRow) -> Json {
  let RateCardRow(level:, day_rate:) = rate
  json.object([
    #("level", json.int(level)),
    #("day_rate", json.float(day_rate)),
  ])
}

/// Decode a `RateCardRow` from a JSON object.
pub fn rate_card_row_decoder() -> Decoder(RateCardRow) {
  use level <- decode.field("level", decode.int)
  use day_rate <- decode.field("day_rate", wire.lenient_float_decoder())
  decode.success(RateCardRow(level:, day_rate:))
}

/// Encode a `SalaryRow` (one salary-table row) as a JSON object.
pub fn encode_salary_row(salary: SalaryRow) -> Json {
  let SalaryRow(level:, monthly_salary:) = salary
  json.object([
    #("level", json.int(level)),
    #("monthly_salary", json.float(monthly_salary)),
  ])
}

/// Decode a `SalaryRow` from a JSON object.
pub fn salary_row_decoder() -> Decoder(SalaryRow) {
  use level <- decode.field("level", decode.int)
  use monthly_salary <- decode.field(
    "monthly_salary",
    wire.lenient_float_decoder(),
  )
  decode.success(SalaryRow(level:, monthly_salary:))
}

/// Encode a `LeavePolicyRow` (one leave-policy row) as a JSON object.
pub fn encode_leave_policy_row(policy: LeavePolicyRow) -> Json {
  let LeavePolicyRow(kind:, level:, days_per_year:) = policy
  json.object([
    #("kind", json.string(kind)),
    #("level", json.int(level)),
    #("days_per_year", json.float(days_per_year)),
  ])
}

/// Decode a `LeavePolicyRow` from a JSON object.
pub fn leave_policy_row_decoder() -> Decoder(LeavePolicyRow) {
  use kind <- decode.field("kind", decode.string)
  use level <- decode.field("level", decode.int)
  use days_per_year <- decode.field(
    "days_per_year",
    wire.lenient_float_decoder(),
  )
  decode.success(LeavePolicyRow(kind:, level:, days_per_year:))
}

/// Encode a `Settings` (the settings read model) to JSON.
pub fn encode_settings(settings: Settings) -> Json {
  let Settings(date:, rate_card:, salaries:, leave_policy:) = settings
  json.object([
    #("date", wire.encode_date(date)),
    #("rate_card", json.array(rate_card, encode_rate_card_row)),
    #("salaries", json.array(salaries, encode_salary_row)),
    #("leave_policy", json.array(leave_policy, encode_leave_policy_row)),
  ])
}

/// Decode a `Settings` from JSON.
pub fn settings_decoder() -> Decoder(Settings) {
  use date <- decode.field("date", wire.date_decoder())
  use rate_card <- decode.field(
    "rate_card",
    decode.list(rate_card_row_decoder()),
  )
  use salaries <- decode.field("salaries", decode.list(salary_row_decoder()))
  use leave_policy <- decode.field(
    "leave_policy",
    decode.list(leave_policy_row_decoder()),
  )
  decode.success(Settings(date:, rate_card:, salaries:, leave_policy:))
}
