//// Web: GET /api/roster?as_of= handler — the operations-console directory for a
//// date. Parse the as-of date, call the domain, encode the result. Imports `wisp`
//// (it owns the HTTP shape) but never `sql` — it talks to the domain `roster`
//// module, which already speaks shared types.
////
//// `as_of` is parsed the same way the board handler parses `date`; the roster
//// returns the engineers employed and the projects active on the date (plus every
//// client) so the console offers only valid names. A missing/malformed `as_of` is
//// a 400; a database failure is a 500.

import gleam/http
import shared/roster/view as roster_view
import tempo/server/context.{type Context}
import tempo/server/roster/view as roster
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/roster?as_of=YYYY-MM-DD — the employed engineers, active
/// projects, and clients the console renders as name `<select>`s for the date.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case roster.roster(ctx, as_of) {
        Ok(directory) ->
          response.json_response(roster_view.encode_roster(directory))
        Error(error) -> response.db_error_response(error)
      }
  }
}
