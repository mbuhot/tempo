//// Wire primitives shared by the per-concept command codecs (`shared/<concept>/command`)
//// and the per-concept read-model codecs (`shared/<concept>/view`): ISO-8601 date
//// encode/parse, the lenient float decoder, and the nullable-date pair. No domain
//// knowledge, so it sits BELOW every codec in the import graph and never forms a cycle.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}

/// Encode a `Date` as an ISO-8601 "YYYY-MM-DD" string.
pub fn encode_date(date: Date) -> Json {
  let Date(year:, month:, day:) = date
  json.string(
    pad4(year) <> "-" <> pad2(calendar.month_to_int(month)) <> "-" <> pad2(day),
  )
}

/// Decode an ISO-8601 "YYYY-MM-DD" string into a `Date`.
pub fn date_decoder() -> Decoder(Date) {
  use text <- decode.then(decode.string)
  case parse_iso_date(text) {
    Ok(date) -> decode.success(date)
    Error(Nil) -> decode.failure(Date(0, calendar.January, 1), "Date")
  }
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `Date`, rejecting any
/// calendar-impossible day (day < 1, a day past the month's length, or Feb 29 in
/// a non-leap year) so a nonsensical `Date` never reaches daterange/money math.
pub fn parse_iso_date(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      let date = Date(year:, month:, day:)
      case calendar.is_valid_date(date) {
        True -> Ok(date)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Decode a JSON number as a `Float`, accepting an integer-valued number too.
///
/// JSON has a single number type, and JavaScript serialises a whole `Float`
/// (e.g. `4.0`) as the integer-looking `4`, whereas Erlang emits `4.0`. A strict
/// `decode.float` then rejects the JS-encoded whole number — which is exactly how
/// a Float fails to cross the JS client -> Erlang server boundary (e.g. timesheet
/// `hours` of `4`). Decoding every Float through this tolerant decoder makes the
/// contract symmetric regardless of which target encoded the value.
pub fn lenient_float_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Encode an `Option(Date)` as `null` (None) or an ISO-8601 string (Some).
pub fn encode_option_date(date: Option(Date)) -> Json {
  json.nullable(date, encode_date)
}

/// Decode an `Option(Date)` from `null` (None) or an ISO-8601 string (Some).
pub fn option_date_decoder() -> Decoder(Option(Date)) {
  decode.optional(date_decoder())
}

/// The all-zero placeholder `Date` a tagged decoder reports as its failure default
/// when no `op` matches (the value is never used — the error is).
pub fn zero_date() -> Date {
  Date(0, calendar.January, 1)
}

fn pad2(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 2, with: "0")
}

fn pad4(value: Int) -> String {
  int.to_string(value) |> string.pad_start(to: 4, with: "0")
}
