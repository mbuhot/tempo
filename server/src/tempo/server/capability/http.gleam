//// Web: GET /api/skills?as_of= handler — the capability & skill taxonomy
//// snapshot. Parse the as-of date, call the domain, encode the result. Imports
//// `wisp` (it owns the HTTP shape) but never `sql` — it talks to the domain
//// `capability` view, which already speaks shared types.
////
//// A missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/skill/view as skill_view
import tempo/server/capability/view as capability
import tempo/server/context.{type Context}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/skills?as_of=YYYY-MM-DD — the capability catalog, skill
/// catalog, and composition matrix as of the date.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case capability.taxonomy(ctx, as_of) {
        Ok(snapshot) ->
          response.json_response(skill_view.encode_taxonomy_snapshot(snapshot))
        Error(error) -> response.db_error_response(error)
      }
  }
}
