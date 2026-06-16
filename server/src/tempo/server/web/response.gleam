//// Web: the shared JSON response helpers reused across the handlers and router.
////
//// A leaf module (it imports only `wisp`/`gleam_json`) so the router can dispatch
//// to handlers that themselves build responses without forming an import cycle.

import gleam/json.{type Json}
import wisp

/// Send an already-encoded JSON value as a 200 response. The shared way handlers
/// return a successful body.
pub fn json_response(body: Json) -> wisp.Response {
  body
  |> json.to_string
  |> wisp.json_response(200)
}

/// A small typed error body: `{error: <code>, detail: <message>}` at `status`.
pub fn error_response(
  status: Int,
  code: String,
  detail: String,
) -> wisp.Response {
  json.object([
    #("error", json.string(code)),
    #("detail", json.string(detail)),
  ])
  |> json.to_string
  |> wisp.json_response(status)
}
