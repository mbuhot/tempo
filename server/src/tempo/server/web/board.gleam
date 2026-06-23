//// Web: GET /api/board handler. Parses the request, calls the domain, encodes the
//// result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks to
//// the domain `board` module, which already speaks shared types.

import gleam/http
import shared/codecs
import tempo/server/board
import tempo/server/context.{type Context}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/board?date=YYYY-MM-DD — compute the org board for a date.
///
/// Thin handler (task spec Notes): parse `date`, run the domain query, encode. A
/// missing/malformed `date` is a 400; a database failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "date") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(date) ->
      case board.snapshot(ctx, date) {
        Ok(snapshot) ->
          response.json_response(codecs.encode_board_snapshot(snapshot))
        Error(error) -> response.db_error_response(error)
      }
  }
}
