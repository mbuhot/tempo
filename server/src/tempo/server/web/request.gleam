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
import gleam/time/calendar.{type Date}
import shared/wire
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

/// Read a REQUIRED integer query parameter. Returns a detail string suitable
/// for a 400 body when absent or non-integer.
pub fn int_from_query(
  request: wisp.Request,
  name: String,
) -> Result(Int, String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Error("missing query parameter '" <> name <> "'")
    Ok(text) ->
      int.parse(text)
      |> result.replace_error(
        "invalid integer '" <> text <> "' for '" <> name <> "'",
      )
  }
}

/// Read an OPTIONAL integer query parameter (e.g. the page `limit`). An absent or
/// empty parameter is `Ok(None)`; a present non-integer is `Error(detail)` for a
/// 400. So only a present-but-malformed value is rejected.
pub fn optional_int_from_query(
  request: wisp.Request,
  name: String,
) -> Result(Option(Int), String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Ok(None)
    Ok("") -> Ok(None)
    Ok(text) ->
      int.parse(text)
      |> result.map(Some)
      |> result.replace_error(
        "invalid integer '" <> text <> "' for '" <> name <> "'",
      )
  }
}

/// Parse an ISO-8601 "YYYY-MM-DD" string into a `calendar.Date`, rejecting
/// calendar-impossible days. Delegates to the shared codec so the query-string
/// boundary and the JSON boundary share one validation.
pub fn parse_iso(text: String) -> Result(Date, Nil) {
  wire.parse_iso_date(text)
}

/// Read a REQUIRED comma-separated list of integer ids (e.g. `required=1,2,3`).
/// Missing or empty is a 400 (the caller must name at least one id); any piece
/// that fails to parse is a 400 naming that piece.
pub fn ids_from_query(
  request: wisp.Request,
  name: String,
) -> Result(List(Int), String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Error("missing query parameter '" <> name <> "'")
    Ok("") -> Error("missing query parameter '" <> name <> "'")
    Ok(text) -> parse_ids(text, name)
  }
}

/// Read an OPTIONAL comma-separated list of integer ids (e.g. `optional=4,5`).
/// An absent or empty parameter is `Ok([])` (no optional attendees); a
/// present-but-malformed piece is `Error(detail)` for a 400.
pub fn optional_ids_from_query(
  request: wisp.Request,
  name: String,
) -> Result(List(Int), String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Ok([])
    Ok("") -> Ok([])
    Ok(text) -> parse_ids(text, name)
  }
}

fn parse_ids(text: String, name: String) -> Result(List(Int), String) {
  text
  |> string.split(",")
  |> list.try_map(fn(piece) {
    int.parse(string.trim(piece))
    |> result.replace_error("invalid id '" <> piece <> "' for '" <> name <> "'")
  })
}
