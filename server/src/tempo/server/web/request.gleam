//// Request parsing at the web boundary: pull a "YYYY-MM-DD" query parameter off a
//// wisp request and turn it into a `calendar.Date`.
////
//// Squirrel rows carry `gleam/time/calendar.Date` and `pog` parameters expect it,
//// and the shared API types hold `calendar.Date` too — so there is no
//// representation to bridge, only the `?as_of=`/`?day=` query string the slider
//// sends to parse. Keeping this parsing here keeps the handlers thin and the
//// domain free of `wisp.Request` (web passes already-parsed values inward).

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import wisp

/// Read a "YYYY-MM-DD" query parameter as an as-of `Date`. Returns a human-readable
/// detail string (for a 400 body) when the parameter is absent or malformed.
pub fn as_of_from_query(
  request: wisp.Request,
  name: String,
) -> Result(Date, String) {
  date_from_query(request, name)
}

/// Read a "YYYY-MM-DD" query parameter as a `calendar.Date`. Returns a detail
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

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `calendar.Date`.
pub fn parse_iso(text: String) -> Result(Date, Nil) {
  case string.split(text, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use month <- result.try(calendar.month_from_int(month))
      use day <- result.try(int.parse(day))
      Ok(Date(year:, month:, day:))
    }
    _ -> Error(Nil)
  }
}
