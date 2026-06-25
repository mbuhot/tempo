//// Pure (no-DB) unit tests for the keyset cursor codec (`tempo/server/web/cursor`,
//// issue #12): each per-shape `encode → decode` is identity, and a corrupted or
//// foreign token decodes to `Error(Nil)` (the handler's signal to answer 400). The
//// token is opaque base64url, so these also prove it survives the round trip the
//// client makes when it echoes a `next_cursor` back.

import gleam/bit_array
import gleam/time/calendar.{Date, June}
import shared/pagination
import tempo/server/web/cursor

// A date+id cursor (invoice keyset) round-trips back to the same bound.
pub fn date_id_round_trips_test() {
  let token = cursor.encode_date_id(Date(2026, June, 1), 42)
  let assert Ok(bound) = cursor.decode_date_id(token)
  assert bound == cursor.DateIdBound(date: Date(2026, June, 1), id: 42)
}

// A name+id cursor (people/client/project keyset) round-trips, including a name
// that itself contains the `|` delimiter — the name is the trailing field, so the
// embedded delimiter is preserved verbatim.
pub fn name_id_round_trips_test() {
  let token = cursor.encode_name_id("Acme | Bros", 7)
  let assert Ok(bound) = cursor.decode_name_id(token)
  assert bound == cursor.NameIdBound(name: "Acme | Bros", id: 7)
}

// An id cursor (the id-DESC journal keyset) round-trips.
pub fn id_round_trips_test() {
  let token = cursor.encode_id(9001)
  let assert Ok(bound) = cursor.decode_id(token)
  assert bound == cursor.IdBound(id: 9001)
}

// A token that is not valid base64url is rejected.
pub fn garbage_token_is_rejected_test() {
  assert cursor.decode_date_id("@@not base64@@") == Error(Nil)
  assert cursor.decode_name_id("@@not base64@@") == Error(Nil)
  assert cursor.decode_id("@@not base64@@") == Error(Nil)
}

// A token minted for a DIFFERENT keyset shape is rejected by arity: a 1-field id
// token does not decode as a 2-field date+id bound, and a 2-field name+id token
// does not decode as a 1-field id bound.
pub fn wrong_shape_token_is_rejected_test() {
  let id_token = cursor.encode_id(5)
  assert cursor.decode_date_id(id_token) == Error(Nil)

  let name_token = cursor.encode_name_id("Acme", 5)
  assert cursor.decode_id(name_token) == Error(Nil)
}

// A well-formed base64url token carrying a NON-`v1` version tag is rejected (a
// future ordering change can rev the version so stale tokens fail loudly rather
// than mis-decode). The token is forged directly so its leading tag is `v99`,
// which the codec's own `encode_cursor` would never emit.
pub fn wrong_version_token_is_rejected_test() {
  let foreign =
    "v99|2026-06-01|1"
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  assert pagination.decode_cursor(foreign, 2) == Error(Nil)
}
