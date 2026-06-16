//// Web: GET/POST /api/timesheet handlers. Parse the request, call the domain,
//// encode the result. Imports `wisp` (it owns the HTTP shape) but never `sql` —
//// it talks to the domain `timesheet` module, which already speaks shared types.
////
//// The POST path decodes the shared `WriteRequest` contract (a malformed body is
//// a 400), logs it via the domain, and on success re-reads the form so the client
//// can re-render. A day with no covering allocation surfaces from the domain as
//// `NotAllocated`, which becomes a clean 422 with a typed error body; any other
//// database failure is a 500.

import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import shared/codecs
import shared/types.{type WriteRequest}
import tempo/server/context.{type Context}
import tempo/server/timesheet
import tempo/server/web/request
import tempo/server/web/response
import wisp

// --- read -------------------------------------------------------------------

/// Handle GET /api/timesheet?engineer=ID&day=YYYY-MM-DD — my allocations on a
/// day, with any logged hours. Missing/malformed params are a 400; a DB failure
/// is a 500.
pub fn handle_read(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case read_params(req) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(engineer_id, day)) -> read_form_response(ctx, engineer_id, day)
  }
}

fn read_params(request: wisp.Request) -> Result(#(Int, Date), String) {
  use engineer_id <- result.try(int_param(request, "engineer"))
  use day <- result.map(request.date_from_query(request, "day"))
  #(engineer_id, day)
}

fn int_param(request: wisp.Request, name: String) -> Result(Int, String) {
  case list.key_find(wisp.get_query(request), name) {
    Error(Nil) -> Error("missing query parameter '" <> name <> "'")
    Ok(text) ->
      int.parse(text)
      |> result.replace_error(
        "invalid integer '" <> text <> "' for '" <> name <> "'",
      )
  }
}

// --- write ------------------------------------------------------------------

/// Handle POST /api/timesheet — log hours for a project on a day. The JSON body
/// is the shared `{engineer_id, project_id, day, hours}` contract. A malformed
/// body is a 400; a day with no covering allocation (the domain's `NotAllocated`)
/// is a clean 422 with a typed error body; any other DB failure is a 500. On
/// success returns the refreshed timesheet form for that engineer/day so the
/// client can re-render.
pub fn handle_write(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)
  case decode.run(body, codecs.write_request_decoder()) {
    Error(_) ->
      response.error_response(
        400,
        "invalid_body",
        "expected {engineer_id, project_id, day, hours}",
      )
    Ok(write) -> log_write(ctx, write)
  }
}

fn log_write(ctx: Context, write: WriteRequest) -> wisp.Response {
  case timesheet.log(ctx, write) {
    Ok(Nil) -> read_form_response(ctx, write.engineer_id, write.day)
    Error(timesheet.NotAllocated) ->
      response.error_response(
        422,
        "not_allocated",
        "the engineer is not allocated to that project on that day",
      )
    Error(timesheet.DatabaseError(_)) -> wisp.internal_server_error()
  }
}

fn read_form_response(
  ctx: Context,
  engineer_id: Int,
  day: Date,
) -> wisp.Response {
  case timesheet.form(ctx, engineer_id, day) {
    Ok(form) -> response.json_response(codecs.encode_timesheet_day(form))
    Error(_) -> wisp.internal_server_error()
  }
}
