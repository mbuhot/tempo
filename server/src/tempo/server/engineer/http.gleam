//// Web: GET /api/engineers/:id?as_of= handler — one engineer's detail. Parse the
//// id and as-of date, call the domain, encode the result. Imports `wisp` (it owns
//// the HTTP shape) but never `sql` — it talks to the domain `engineer_detail`
//// module, which already speaks shared types.
////
//// A non-integer id or a missing/malformed `as_of` is a 400; an unknown engineer
//// is a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/time/calendar.{type Date}
import shared/engineer/view as engineer_view
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/engineer/view as engineer_detail
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/engineers/:id?as_of=YYYY-MM-DD — the engineer's profile,
/// contact/banking/emergency, as-of employment, role/allocation/leave history, and
/// leave balance. Authorized to a principal with `read.engineers`, or the engineer
/// reading their OWN record. A non-integer id is a 400, an unauthorized read a 403, an
/// unknown id a 404.
pub fn handle_detail(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
  principal: Principal,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid engineer id '" <> id_segment <> "'")
    Ok(engineer_id) ->
      case auth.can_read_engineer(principal, engineer_id) {
        False ->
          response.error_response(
            403,
            "forbidden",
            "you do not have permission to view this engineer",
          )
        True ->
          case request.date_from_query(req, "as_of") {
            Error(detail) -> wisp.bad_request(detail)
            Ok(as_of) -> detail_response(ctx, engineer_id, as_of)
          }
      }
  }
}

fn detail_response(
  ctx: Context,
  engineer_id: Int,
  as_of: Date,
) -> wisp.Response {
  case engineer_detail.detail(ctx, engineer_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(engineer_view.encode_engineer_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
