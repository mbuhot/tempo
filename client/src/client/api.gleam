//// The client's HTTP seam: a generic JSON `get`, the `login` POST, the operations
//// `submit_operation` POST, and a shared error describer. One home for these so
//// pages never import the shell (which would cycle) and the write path is not
//// copied per page.
////
//// Identity is now SERVER-side (issue #6): `login` authenticates the chosen
//// identity and the server replies with a signed session cookie. The browser then
//// carries that cookie on every same-origin request, so `submit_operation` no
//// longer puts an `actor` on the wire — the server derives it from the session and
//// stamps it on the event log. A forged actor in the body is no longer possible.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import lustre/effect.{type Effect}
import rsvp
import shared/codecs
import shared/types.{type Command, type Event, OperationRequest}

/// Fetch JSON from `url`, decode it with `decoder`, and hand the outcome to
/// `to_msg`. A non-2xx arrives as `rsvp.HttpError` carrying the response body so
/// the caller can surface a typed error.
pub fn get(
  url: String,
  decoder: Decoder(a),
  to_msg: fn(Result(a, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.get(url, rsvp.expect_json(decoder, to_msg))
}

/// POST `{actor}` to `/api/login` to authenticate an identity. On success the
/// server sets a signed session cookie (carried automatically on later requests)
/// and echoes the authenticated `actor`, decoded out of the `{actor, role}` body
/// and handed to `to_msg`. An unknown identity is a 401 (an `rsvp.HttpError`).
pub fn login(
  actor: String,
  to_msg: fn(Result(String, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  let body = json.object([#("actor", json.string(actor))])
  let decoder = {
    use authenticated <- decode.field("actor", decode.string)
    decode.success(authenticated)
  }
  rsvp.post("/api/login", body, rsvp.expect_json(decoder, to_msg))
}

/// POST `{command}` to `/api/operations` on the authenticated session's behalf.
/// The actor is NO LONGER on the wire — the server derives it from the session
/// cookie the browser carries (issue #6). The server returns the created `Event`s
/// as a JSON array on success (the journal rows the dispatch appended) and a typed
/// `{error, detail}` body on a 4xx/5xx, which arrives as an `rsvp.HttpError`
/// carrying that body — render it with `describe_error`.
pub fn submit_operation(
  command: Command,
  to_msg: fn(Result(List(Event), rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  let body = codecs.encode_operation_request(OperationRequest(command:))
  let handler = rsvp.expect_json(decode.list(codecs.event_decoder()), to_msg)
  rsvp.post("/api/operations", body, handler)
}

/// Turn an `rsvp.Error` into a human sentence. A classified 4xx/5xx
/// (`ContainmentViolated`/`OverlappingFact`/`InvalidValue`) arrives as
/// `HttpError` carrying the typed `{error, detail}` body; we surface the `detail`
/// so the user sees exactly why the request was refused rather than a raw status.
pub fn describe_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.HttpError(response) ->
      case codecs.decode_error_detail(response.body) {
        Ok(detail) -> detail
        Error(Nil) -> "the request was rejected"
      }
    rsvp.BadBody -> "the response body was malformed"
    rsvp.BadUrl(url) -> "the request URL was invalid: " <> url
    rsvp.JsonError(_) -> "the response could not be decoded"
    rsvp.NetworkError -> "could not reach the API"
    rsvp.UnhandledResponse(_) -> "the response was not understood"
  }
}
