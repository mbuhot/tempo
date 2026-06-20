//// Web: GET /api/people?as_of= handler — the people roster for a date. Parse the
//// as-of date, call the domain, encode the result. Imports `wisp` (it owns the HTTP
//// shape) but never `sql` — it talks to the domain `people` module, which already
//// speaks shared types.
////
//// A missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/people
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/people?as_of=YYYY-MM-DD — every employed engineer's roster row
/// as of the date (level, status, allocation, annual balance, day rate).
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case people.roster(ctx, as_of) {
        Ok(list) -> response.json_response(codecs.encode_people_list(list))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
