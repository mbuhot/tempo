//// Web: GET /api/schedule, GET /api/schedule/candidates, and the scenario
//// POST /api/schedule/preview + /apply handlers. Parses the request, calls the
//// domain, encodes the result. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it talks to the domain `schedule` module, which already
//// speaks shared types.
////
//// The scenario endpoints authenticate the request (a signed session cookie,
//// like `POST /api/operations`) but carry NO route-level permission guard —
//// each drafted operation is authorized individually inside the executor,
//// exactly like the single-command write seam.

import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/json
import gleam/result
import gleam/time/calendar.{type Date}
import shared/command as gateway
import shared/schedule/view as shared_schedule
import shared/wire
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/operation.{type OperationError}
import tempo/server/schedule/executor
import tempo/server/schedule/view as schedule
import tempo/server/web/guard
import tempo/server/web/operations
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

/// The scenario request body: `{as_of, operations}`, decoded through the same
/// shared `Command` codec `POST /api/operations` uses.
fn scenario_decoder() -> Decoder(#(Date, List(gateway.Command))) {
  use as_of <- decode.field("as_of", wire.date_decoder())
  use operations <- decode.field(
    "operations",
    decode.list(gateway.command_decoder()),
  )
  decode.success(#(as_of, operations))
}

/// Handle POST /api/schedule/preview — run the scenario's drafts inside a
/// rolled-back transaction and return the resulting timeline with a per-op
/// outcome; nothing is written.
pub fn handle_preview(req: wisp.Request, ctx: Context) -> wisp.Response {
  scenario_endpoint(req, ctx, executor.preview)
}

/// Handle POST /api/schedule/apply — run the scenario's drafts as one
/// all-or-nothing batch and commit.
pub fn handle_apply(req: wisp.Request, ctx: Context) -> wisp.Response {
  scenario_endpoint(req, ctx, executor.apply)
}

fn scenario_endpoint(
  req: wisp.Request,
  ctx: Context,
  run: fn(Context, Principal, Date, List(gateway.Command)) ->
    Result(shared_schedule.PreviewResult, OperationError),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use principal <- guard.authenticated(ctx)
  use body <- wisp.require_json(req)
  case decode.run(body, scenario_decoder()) {
    Error(_) -> wisp.bad_request("expected {as_of, operations}")
    Ok(#(as_of, commands)) ->
      case run(ctx, principal, as_of, commands) {
        Ok(result) ->
          response.json_response(shared_schedule.encode_preview_result(result))
        Error(error) -> operations.error_response(error)
      }
  }
}
