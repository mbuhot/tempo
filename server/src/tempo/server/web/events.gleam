//// Web: GET /api/events handler. Calls the domain, encodes the result. Imports
//// `wisp` (it owns the HTTP shape) but never `sql` — it talks to the domain
//// `event` module, which already speaks shared types.

import gleam/http
import gleam/json
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/event
import tempo/server/web/response
import wisp

/// Handle GET /api/events — list the provenance journal newest-first.
///
/// Thin handler (task spec Notes): run the domain query, encode each `Event` to
/// a JSON array. A database failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case event.list(ctx) {
    Ok(events) ->
      response.json_response(json.array(events, codecs.encode_event))
    Error(_) -> wisp.internal_server_error()
  }
}
