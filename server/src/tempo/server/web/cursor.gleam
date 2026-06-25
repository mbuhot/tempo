//// Server-side keyset cursor codec (issue #12): the bridge between the opaque
//// `shared/pagination` token the client echoes and the typed keyset BOUNDS the
//// paginated SQL takes. Each list orders on its own tuple, so this exposes one
//// build/parse pair per keyset SHAPE:
////
////  - date+id  — invoice_list (lower(billing_period), id)
////  - name+id  — people_list / client_list / project_list (display name, id)
////  - id       — event_log_list (id DESC)
////
//// The SQL params are NON-nullable (Squirrel never infers nullable params), so
//// "no cursor" (the first page) is expressed as a SENTINEL bound that precedes (or,
//// for the DESC journal, follows) every real row — never skipping anything. The
//// handler passes the sentinel when the request omits `cursor`, and a present cursor
//// that fails to decode is the caller's signal to answer 400.

import gleam/int
import gleam/string
import gleam/time/calendar.{type Date}
import shared/pagination
import shared/wire

/// The keyset lower bound for a date+id ordered list (invoice_list): the
/// billing-from `date` and `id` of the last row already returned. The first page's
/// sentinel is `('0001-01-01', 0)`, which sorts before every real row.
pub type DateIdBound {
  DateIdBound(date: Date, id: Int)
}

/// The first-page sentinel for a date+id list: a date before any real row and id 0.
pub fn date_id_start() -> DateIdBound {
  DateIdBound(date: wire.zero_date(), id: 0)
}

/// Build the opaque cursor for a date+id row's `date` and `id`.
pub fn encode_date_id(date: Date, id: Int) -> String {
  pagination.encode_cursor([iso_date(date), int.to_string(id)])
}

/// Parse a date+id cursor token into its bound, or `Error(Nil)` on a malformed
/// token (bad base64, bad version, wrong arity, or unparseable parts).
pub fn decode_date_id(token: String) -> Result(DateIdBound, Nil) {
  case pagination.decode_cursor(token, 2) {
    Ok([date_text, id_text]) ->
      case wire.parse_iso_date(date_text), int.parse(id_text) {
        Ok(date), Ok(id) -> Ok(DateIdBound(date:, id:))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The keyset lower bound for a name+id ordered list (people/client/project): the
/// display `name` and `id` of the last row already returned. The first page's
/// sentinel is `('', 0)`, which sorts before every real row (every name is `>= ''`,
/// and the id tiebreaker keeps even a row whose name is exactly `''`).
pub type NameIdBound {
  NameIdBound(name: String, id: Int)
}

/// The first-page sentinel for a name+id list: the empty name and id 0.
pub fn name_id_start() -> NameIdBound {
  NameIdBound(name: "", id: 0)
}

/// Build the opaque cursor for a name+id row. The id leads and the (free-text,
/// possibly `|`-bearing) name trails so the decode split is unambiguous.
pub fn encode_name_id(name: String, id: Int) -> String {
  pagination.encode_cursor([int.to_string(id), name])
}

/// Parse a name+id cursor token into its bound, or `Error(Nil)` on a malformed
/// token. The name is the trailing field (any embedded `|` preserved).
pub fn decode_name_id(token: String) -> Result(NameIdBound, Nil) {
  case pagination.decode_cursor(token, 2) {
    Ok([id_text, name]) ->
      case int.parse(id_text) {
        Ok(id) -> Ok(NameIdBound(name:, id:))
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The keyset upper bound for the id-DESC journal (event_log_list): the `id` of the
/// last row already returned. The first page's sentinel is one past the largest
/// possible id, so `id < sentinel` admits every row.
pub type IdBound {
  IdBound(id: Int)
}

/// The first-page sentinel for an id-DESC list: a value above every real id, so the
/// `id < $cursor` predicate admits the whole journal.
pub fn id_desc_start() -> IdBound {
  IdBound(id: id_ceiling)
}

/// A value above every real `event_log.id` (a bigserial), used as the first-page
/// sentinel upper bound for the DESC journal.
pub const id_ceiling = 9_223_372_036_854_775_807

/// Build the opaque cursor for an id-DESC row's `id`.
pub fn encode_id(id: Int) -> String {
  pagination.encode_cursor([int.to_string(id)])
}

/// Parse an id-DESC cursor token into its bound, or `Error(Nil)` on a malformed
/// token.
pub fn decode_id(token: String) -> Result(IdBound, Nil) {
  case pagination.decode_cursor(token, 1) {
    Ok([id_text]) ->
      case int.parse(id_text) {
        Ok(id) -> Ok(IdBound(id:))
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn iso_date(date: Date) -> String {
  let calendar.Date(year:, month:, day:) = date
  pad(year, 4)
  <> "-"
  <> pad(calendar.month_to_int(month), 2)
  <> "-"
  <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  int.to_string(value) |> string.pad_start(to: width, with: "0")
}
