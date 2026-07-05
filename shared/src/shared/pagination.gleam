//// Keyset (cursor) pagination primitives shared by every paginated list endpoint
//// (issue #12). A `Cursor` is an OPAQUE, server-minted token: the client never
//// reads its contents, it only echoes the `next_cursor` it was handed back to ask
//// for the following page. The token is the base64url encoding of a `|`-delimited,
//// versioned string of the last returned row's ordering key(s) — so it round-trips
//// identically on both the JS client and the Erlang server.
////
//// This module owns only the WIRE shape: the opaque-string encode/decode and the
//// `Page` envelope's `next_cursor` field codec. Building the keyset string from a
//// row's ordering tuple, and turning a decoded token back into SQL bounds, is
//// server-side (`tempo/server/web/cursor`) — the client treats the whole thing as
//// an opaque `String` it carries on the wire.

import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The version tag stamped at the head of every cursor's plaintext, so an older
/// client's token from a future ordering change can be detected and rejected
/// rather than silently mis-decoded.
const cursor_version = "v1"

/// Encode the already-built keyset `fields` of the last row into an opaque
/// base64url cursor token. `fields` are the ordering-key components in ORDER BY
/// order (e.g. `["2026-06-01", "42"]`); they must not themselves contain the `|`
/// delimiter (the callers pass ISO dates, plain integers, and names — names are
/// the one free-text case, see `decode`).
pub fn encode_cursor(fields: List(String)) -> String {
  [cursor_version, ..fields]
  |> string.join("|")
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

/// Decode an opaque cursor token back into its keyset `fields` (the components
/// after the version tag), or `Error(Nil)` when the token is not valid base64url,
/// is not UTF-8, or does not carry the expected version tag. A malformed cursor is
/// the caller's signal to answer 400.
///
/// Names can contain `|`; to keep the split unambiguous the callers only ever put
/// a name in the LAST field, so this splits into at most `expected_fields + 1`
/// pieces (version + fields) and the final field keeps any embedded delimiter.
pub fn decode_cursor(
  token: String,
  expected_fields: Int,
) -> Result(List(String), Nil) {
  case bit_array.base64_url_decode(token) {
    Error(Nil) -> Error(Nil)
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Error(Nil) -> Error(Nil)
        Ok(text) -> split_versioned(text, expected_fields)
      }
  }
}

fn split_versioned(
  text: String,
  expected_fields: Int,
) -> Result(List(String), Nil) {
  case string.split_once(text, "|") {
    Ok(#(version, rest)) if version == cursor_version ->
      Ok(split_keeping_last(rest, expected_fields))
    _ -> Error(Nil)
  }
}

/// Split `text` on `|` into at most `count` pieces, the final piece keeping any
/// remaining delimiters (so a trailing free-text name is preserved verbatim).
fn split_keeping_last(text: String, count: Int) -> List(String) {
  case count <= 1 {
    True -> [text]
    False ->
      case string.split_once(text, "|") {
        Ok(#(head, rest)) -> [head, ..split_keeping_last(rest, count - 1)]
        Error(Nil) -> [text]
      }
  }
}

/// Encode a `next_cursor` field value: `null` when the page is the last one (no
/// more rows), otherwise the opaque cursor string.
pub fn encode_next_cursor(next: Option(String)) -> Json {
  json.nullable(next, json.string)
}

/// Decode a `next_cursor` field value: `null`/absent becomes `None`, a string
/// becomes `Some(cursor)`.
pub fn next_cursor_decoder() -> Decoder(Option(String)) {
  decode.optional(decode.string)
}

/// Given the rows fetched with `limit + 1` (the look-ahead row that tells us
/// whether a further page exists) and a `to_cursor` that builds a row's keyset
/// token, return the page's rows trimmed to `limit` and the `next_cursor` for the
/// following page (`None` when fewer than `limit + 1` rows came back, i.e. the
/// page is the last one).
pub fn paginate(
  fetched: List(row),
  limit: Int,
  to_cursor: fn(row) -> String,
) -> #(List(row), Option(String)) {
  let rows = list.take(fetched, limit)
  case list.length(fetched) > limit {
    True ->
      case list.last(rows) {
        Ok(last_row) -> #(rows, Some(to_cursor(last_row)))
        Error(Nil) -> #(rows, None)
      }
    False -> #(rows, None)
  }
}

/// Encode a simple integer row-offset as an opaque cursor, for list endpoints
/// whose keyset is just "how many rows have been returned so far".
pub fn encode_offset(offset: Int) -> String {
  encode_cursor([int.to_string(offset)])
}

/// Decode an offset cursor back into the row count to skip; `None` (first page)
/// and any malformed token both fall back to `0`.
pub fn decode_offset(cursor: Option(String)) -> Int {
  case cursor {
    None -> 0
    Some(token) ->
      case decode_cursor(token, 1) {
        Ok([text]) -> result.unwrap(int.parse(text), 0)
        _ -> 0
      }
  }
}
