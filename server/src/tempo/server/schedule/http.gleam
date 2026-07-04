//// Web: GET /api/schedule handler. Parses the request, calls the domain,
//// encodes the result. Imports `wisp` (it owns the HTTP shape) but never
//// `sql` — it talks to the domain `schedule` module, which already speaks
//// shared types.

import gleam/http
import shared/schedule/view as shared_schedule
import tempo/server/context.{type Context}
import tempo/server/schedule/view as schedule
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/schedule?as_of=YYYY-MM-DD — compute the 12-week allocation
/// timeline for the date. A missing/malformed `as_of` is a 400; a database
/// failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case schedule.timeline(ctx.db, as_of) {
        Ok(timeline) ->
          response.json_response(shared_schedule.encode_schedule(timeline))
        Error(error) -> response.db_error_response(error)
      }
  }
}
