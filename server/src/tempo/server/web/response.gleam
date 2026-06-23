//// Web: the shared JSON response helpers reused across the handlers and router.
////
//// A leaf module (it imports only `wisp`/`gleam_json`) so the router can dispatch
//// to handlers that themselves build responses without forming an import cycle.

import gleam/json.{type Json}
import pog
import wisp

/// Send an already-encoded JSON value as a 200 response. The shared way handlers
/// return a successful body.
pub fn json_response(body: Json) -> wisp.Response {
  body
  |> json.to_string
  |> wisp.json_response(200)
}

/// Map a database `pog.QueryError` to an HTTP response. Pool exhaustion — a
/// checkout that timed out waiting for a free connection (`QueryTimeout`) or no
/// connection available at all (`ConnectionUnavailable`) — is a transient
/// capacity problem, so it surfaces as **503 Service Unavailable** (a retryable
/// status) rather than masquerading as a 500. Every other query error is a
/// genuine server fault and stays a 500.
pub fn db_error_response(error: pog.QueryError) -> wisp.Response {
  case error {
    pog.QueryTimeout | pog.ConnectionUnavailable ->
      error_response(
        503,
        "unavailable",
        "the database connection pool is saturated; retry shortly",
      )
    _ -> wisp.internal_server_error()
  }
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
