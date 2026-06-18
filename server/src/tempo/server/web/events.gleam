//// Web: GET /api/events handler. Parses the request, calls the domain, encodes
//// the result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks
//// to the domain `event` module, which already speaks shared types.

import gleam/http
import gleam/json
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/event
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/events?date=YYYY-MM-DD — the provenance journal newest-first,
/// as of the slider date: only operations effective on or before that date are
/// returned, so the feed scrubs with the rest of the UI.
///
/// Thin handler (task spec Notes): parse the as-of date, run the domain query,
/// encode each `Event` to a JSON array. A missing/malformed date is a 400; a
/// database failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "date") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case event.list(ctx, as_of) {
        Ok(events) ->
          response.json_response(json.array(events, codecs.encode_event))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
