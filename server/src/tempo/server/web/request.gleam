//// Request parsing at the web boundary: pull a "YYYY-MM-DD" query parameter off a
//// wisp request and turn it into a `calendar.Date`.
////
//// Squirrel rows carry `gleam/time/calendar.Date` and `pog` parameters expect it,
//// and the shared API types hold `calendar.Date` too — so there is no
//// representation to bridge, only the `?date=`/`?day=` query string the slider
//// sends to parse. Keeping this parsing here keeps the handlers thin and the
//// domain free of `wisp.Request` (web passes already-parsed values inward).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import wisp

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

/// Read an OPTIONAL "YYYY-MM-DD" query parameter as a `calendar.Date`. An absent
/// parameter is `Ok(None)` (the filter is simply dropped); a present parameter that
/// fails to parse is `Error(detail)` for a 400. So only a present-but-malformed
/// value is rejected.
pub fn optional_date_from_query(
  request: wisp.Request,
  name: String,
) -> Result(Option(Date), String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Ok(None)
    Ok(text) ->
      parse_iso(text)
      |> result.map(Some)
      |> result.replace_error(
        "invalid date '" <> text <> "' for '" <> name <> "' (want YYYY-MM-DD)",
      )
  }
}

/// Read an OPTIONAL query parameter as a raw string. An absent parameter is `None`;
/// an empty string is also treated as absent (so a cleared filter drops, never
/// matches the empty string).
pub fn optional_string_from_query(
  request: wisp.Request,
  name: String,
) -> Option(String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> None
    Ok("") -> None
    Ok(text) -> Some(text)
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
