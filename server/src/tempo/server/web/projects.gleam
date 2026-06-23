//// Web: the project read handlers — GET /api/projects?as_of= (list) and
//// GET /api/projects/:id?as_of= (detail). Parse the request, call the domain, encode
//// the result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks
//// to the domain `project_detail` module, which already speaks shared types.
////
//// Both reads take an `as_of` date: the list shows each project's active flag and
//// team size as of the date, the detail its run active flag, team and invoices as
//// of the date. A missing/malformed `as_of` is a 400; an unknown project id is a
//// 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/time/calendar.{type Date}
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/project_detail
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/projects?as_of=YYYY-MM-DD — every project with a run, its client,
/// budget, target, team size, and active flag as of the date.
pub fn handle_list(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case project_detail.list(ctx, as_of) {
        Ok(list) -> response.json_response(codecs.encode_project_list(list))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/projects/:id?as_of=YYYY-MM-DD — one project's profile, plan,
/// client, run period, team, and invoices as of the date. A non-integer id is a
/// 400, an unknown id a 404.
pub fn handle_detail(
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
        Ok(as_of) -> detail_response(ctx, project_id, as_of)
      }
  }
}

fn detail_response(
  ctx: Context,
  project_id: Int,
  as_of: Date,
) -> wisp.Response {
  case project_detail.detail(ctx, project_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(codecs.encode_project_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
