//// Web: GET /api/timesheet handler (the form for a day). Parse the request, call
//// the domain, encode the result. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it talks to the domain `timesheet` module, which already speaks
//// shared types.
////
//// There is no POST here: logging hours is a `LogTimesheet` command applied
//// through `POST /api/operations` like every other write (§5a), so this module
//// reads only.

import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/timesheet
import tempo/server/web/request
import tempo/server/web/response
import wisp

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
