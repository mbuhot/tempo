//// Web: GET /api/engineers/:id/skills?as_of= handler — one engineer's skill
//// matrix, capability rollups, and assessment history. Parse the id and as-of
//// date, call the domain, encode the result. Imports `wisp` (it owns the HTTP
//// shape) but never `sql` — it talks to the domain `engineer_skill` view, which
//// already speaks shared types.
////
//// A non-integer id or a missing/malformed `as_of` is a 400; an unauthorized
//// read a 403; an unknown engineer is a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/time/calendar.{type Date}
import shared/skill/view as skill_view
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/engineer_skill/view as engineer_skill
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/engineers/:id/skills?as_of=YYYY-MM-DD. Authorized to a
/// principal with `read.engineers`, or the engineer reading their OWN record.
pub fn handle(
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
            Ok(as_of) -> skills_response(ctx, engineer_id, as_of)
          }
      }
  }
}

fn skills_response(
  ctx: Context,
  engineer_id: Int,
  as_of: Date,
) -> wisp.Response {
  case engineer_skill.skills(ctx, engineer_id, as_of) {
    Ok(Ok(skills)) ->
      response.json_response(skill_view.encode_engineer_skills(skills))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
