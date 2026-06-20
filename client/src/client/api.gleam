//// The client's HTTP seam: a generic JSON `get`, the operations `submit_operation`
//// POST, and a shared error describer. One home for these so pages never import
//// the shell (which would cycle) and the write path is not copied per page.
////
//// `submit_operation` is parameterised by the signed-in actor (ADR-035),
//// replacing the old hardcoded `console_actor`: the actor flows from the shell's
//// login gate into the `{actor, command}` envelope the server stamps onto the
//// event log.

import gleam/dynamic/decode.{type Decoder}
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

/// POST `{actor, command}` to `/api/operations` on the signed-in actor's behalf.
/// The server returns the created `Event`s as a JSON array on success (the
/// journal rows the dispatch appended) and a typed `{error, detail}` body on a
/// 4xx/5xx, which arrives as an `rsvp.HttpError` carrying that body — render it
/// with `describe_error`.
pub fn submit_operation(
  actor: String,
  command: Command,
  to_msg: fn(Result(List(Event), rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  let body = codecs.encode_operation_request(OperationRequest(actor:, command:))
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
