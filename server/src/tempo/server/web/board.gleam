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

/// Handle GET /api/board?as_of=YYYY-MM-DD — compute the org board as of a date.
///
/// Thin handler (task spec Notes): parse `as_of`, run the domain query, encode. A
/// missing/malformed `as_of` is a 400; a database failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.as_of_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case board.snapshot(ctx, as_of) {
        Ok(snapshot) ->
          response.json_response(codecs.encode_board_snapshot(snapshot))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
