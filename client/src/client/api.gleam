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
import gleam/option.{type Option}
import lustre/effect.{type Effect}
import rsvp
import shared/command.{
  type Command, type Event, OperationRequest, decode_error_detail,
  encode_operation_request, event_decoder,
}

/// The signed-in identity the login endpoint returns: the journal actor, the linked
/// engineer (for own-resource UI), and the effective permission keys (for UI gating).
pub type Identity {
  Identity(actor: String, engineer_id: Option(Int), permissions: List(String))
}

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

/// POST `{username, password, remember_me}` to `/api/login`. On success the server
/// verifies the password, sets a signed session cookie (persistent when
/// `remember_me`, else a session cookie cleared on browser close), and echoes the
/// authenticated `actor` — decoded out of the `{actor, role}` body and handed to
/// `to_msg`. Bad credentials are a uniform 401 (an `rsvp.HttpError`).
pub fn login(
  username: String,
  password: String,
  remember_me: Bool,
  to_msg: fn(Result(Identity, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  let body =
    json.object([
      #("username", json.string(username)),
      #("password", json.string(password)),
      #("remember_me", json.bool(remember_me)),
    ])
  rsvp.post("/api/login", body, rsvp.expect_json(identity_decoder(), to_msg))
}

/// GET `/api/me` — the authenticated identity + effective permissions, resolved as-of
/// now (the canonical source). The client calls it on boot to restore a session from
/// the cookie, and to refresh permissions after a change. A missing/invalid session is
/// a 401 (`rsvp.HttpError`), which the shell treats as "show the gate".
pub fn me(
  to_msg: fn(Result(Identity, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  get("/api/me", identity_decoder(), to_msg)
}

fn identity_decoder() -> Decoder(Identity) {
  use actor <- decode.field("actor", decode.string)
  use engineer_id <- decode.field("engineer_id", decode.optional(decode.int))
  use permissions <- decode.field("permissions", decode.list(decode.string))
  decode.success(Identity(actor:, engineer_id:, permissions:))
}

/// POST to `/api/logout` to clear the session cookie server-side. The client also
/// drops its local actor and returns to the gate, so the result is ignored.
pub fn logout(
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/logout",
    json.object([]),
    rsvp.expect_json(decode.success(Nil), to_msg),
  )
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
  let body = encode_operation_request(OperationRequest(command:))
  let handler = rsvp.expect_json(decode.list(event_decoder()), to_msg)
  rsvp.post("/api/operations", body, handler)
}

/// Turn an `rsvp.Error` into a human sentence. A classified 4xx/5xx
/// (`ContainmentViolated`/`OverlappingFact`/`InvalidValue`) arrives as
/// `HttpError` carrying the typed `{error, detail}` body; we surface the `detail`
/// so the user sees exactly why the request was refused rather than a raw status.
pub fn describe_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.HttpError(response) ->
      case decode_error_detail(response.body) {
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
