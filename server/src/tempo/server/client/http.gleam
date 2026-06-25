//// Web: the client read handlers — GET /api/clients?as_of= (list) and
//// GET /api/clients/:id?as_of= (detail). Parse the request, call the domain, encode
//// the result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks
//// to the domain `client_detail` module, which already speaks shared types.
////
//// Both reads take an `as_of` date: the list shows each client's active flag as of
//// the date, the detail computes its contract/project active flags as of the date
//// (the profile name is durable). A missing/malformed `as_of` is a 400; an unknown
//// client id is a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/time/calendar.{type Date}
import shared/client/view as client_view
import tempo/server/client/view as client_detail
import tempo/server/context.{type Context}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/clients?as_of=YYYY-MM-DD — every client with its `since`,
/// project count, and active flag as of the date.
pub fn handle_list(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case client_detail.list(ctx, as_of) {
        Ok(list) -> response.json_response(client_view.encode_client_list(list))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/clients/:id?as_of=YYYY-MM-DD — one client's profile, `since`,
/// contracts, and projects (active flags as of the date). A non-integer id is a
/// 400, an unknown id a 404.
pub fn handle_detail(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid client id '" <> id_segment <> "'")
    Ok(client_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) -> detail_response(ctx, client_id, as_of)
      }
  }
}

fn detail_response(ctx: Context, client_id: Int, as_of: Date) -> wisp.Response {
  case client_detail.detail(ctx, client_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(client_view.encode_client_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
