//// Web: GET /api/schedule and GET /api/schedule/candidates handlers. Parses
//// the request, calls the domain, encodes the result. Imports `wisp` (it owns
//// the HTTP shape) but never `sql` — it talks to the domain `schedule`
//// module, which already speaks shared types.

import gleam/http
import gleam/json
import gleam/result
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

/// Handle GET /api/schedule/candidates?as_of=&project=&level=&from=&to= —
/// list every employed engineer qualifying for the given level seat, with a
/// worst-week free fraction over the window and a capability rollup. A
/// missing/malformed query parameter is a 400; a database failure is a 500.
pub fn handle_candidates(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let params = {
    use as_of <- result.try(request.date_from_query(req, "as_of"))
    use project <- result.try(request.int_from_query(req, "project"))
    use level <- result.try(request.int_from_query(req, "level"))
    use from <- result.try(request.date_from_query(req, "from"))
    use to <- result.map(request.date_from_query(req, "to"))
    #(as_of, project, level, from, to)
  }
  case params {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(as_of, project, level, from, to)) ->
      case schedule.candidates(ctx.db, as_of, project, level, from, to) {
        Ok(candidates) ->
          response.json_response(json.array(
            candidates,
            shared_schedule.encode_candidate,
          ))
        Error(error) -> response.db_error_response(error)
      }
  }
}
