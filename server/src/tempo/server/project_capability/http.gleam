//// Web: GET /api/projects/:id/coverage?as_of= handler — the project's
//// capability catalog and coverage requirements. Parse the id and as-of date,
//// call the domain, encode the result. Imports `wisp` (it owns the HTTP shape)
//// but never `sql` — it talks to the domain `project_capability` view, which
//// already speaks shared types.
////
//// A non-integer id or a missing/malformed `as_of` is a 400; an unknown
//// project is a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/time/calendar.{type Date}
import shared/project_capability/view as coverage_view
import tempo/server/context.{type Context}
import tempo/server/project_capability/view as project_capability
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/projects/:id/coverage?as_of=YYYY-MM-DD.
pub fn handle(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid project id '" <> id_segment <> "'")
    Ok(project_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) -> coverage_response(ctx, project_id, as_of)
      }
  }
}

fn coverage_response(
  ctx: Context,
  project_id: Int,
  as_of: Date,
) -> wisp.Response {
  case project_capability.coverage(ctx, project_id, as_of) {
    Ok(Ok(snapshot)) ->
      response.json_response(coverage_view.encode_coverage_snapshot(snapshot))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
