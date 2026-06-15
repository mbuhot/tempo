//// Target: Erlang only — date conversions at the server boundary.
////
//// Bridges three date representations the server straddles:
////   * `gleam/time/calendar.Date` — what Squirrel rows carry and `pog`
////     parameters expect (the range bounds decomposed per ADR-011).
////   * `shared/types.{Date, AsOf}` — the target-agnostic API contract
////     (plain Int components, ADR-005) the codecs serialise.
////   * the `?as_of=`/`?day=` query string the slider sends as "YYYY-MM-DD".
////
//// Keeping these conversions in one place keeps the handlers thin (task spec
//// Notes: "Keep mapping in one place").

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import shared/types.{type AsOf, type Date, AsOf, Date}
import wisp

/// A `calendar.Date` (a Squirrel row bound) → the shared API `Date`.
pub fn from_calendar(date: calendar.Date) -> Date {
  let calendar.Date(year:, month:, day:) = date
  Date(year:, month: calendar.month_to_int(month), day:)
}

/// The shared `AsOf` instant → a `calendar.Date` for a `pog` query parameter.
pub fn as_of_to_calendar(as_of: AsOf) -> calendar.Date {
  let AsOf(year:, month:, day:) = as_of
  calendar.Date(year:, month: int_to_month(month), day:)
}

/// A shared `Date` → a `calendar.Date` for a `pog` query parameter.
pub fn to_calendar(date: Date) -> calendar.Date {
  let Date(year:, month:, day:) = date
  calendar.Date(year:, month: int_to_month(month), day:)
}

/// Read a "YYYY-MM-DD" query parameter as an `AsOf`. Returns a human-readable
/// detail string (for a 400 body) when the parameter is absent or malformed.
pub fn as_of_from_query(
  request: wisp.Request,
  name: String,
) -> Result(AsOf, String) {
  use date <- result.map(date_from_query(request, name))
  let Date(year:, month:, day:) = date
  AsOf(year:, month:, day:)
}

/// Read a "YYYY-MM-DD" query parameter as a shared `Date`. Returns a detail
/// string suitable for a 400 body when absent or malformed.
pub fn date_from_query(
  request: wisp.Request,
  name: String,
) -> Result(Date, String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Error("missing query parameter '" <> name <> "'")
    Ok(text) ->
      parse_iso(text)
      |> result.replace_error(
        "invalid date '" <> text <> "' for '" <> name <> "' (want YYYY-MM-DD)",
      )
  }
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a shared `Date`.
pub fn parse_iso(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use day <- result.try(int.parse(day))
      case month >= 1 && month <= 12 {
        True -> Ok(Date(year:, month:, day:))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn int_to_month(month: Int) -> calendar.Month {
  case month {
    1 -> calendar.January
    2 -> calendar.February
    3 -> calendar.March
    4 -> calendar.April
    5 -> calendar.May
    6 -> calendar.June
    7 -> calendar.July
    8 -> calendar.August
    9 -> calendar.September
    10 -> calendar.October
    11 -> calendar.November
    _ -> calendar.December
  }
}
