//// Web: GET /api/timesheet handler (the weekly grid). Parse the request, call
//// the domain, encode the result. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it talks to the domain `timesheet` module, which already speaks
//// shared types.
////
//// There is no POST here: logging hours is a `LogWeek` command applied
//// through `POST /api/operations` like every other write, so this module
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

/// Handle GET /api/timesheet?engineer=ID&week=YYYY-MM-DD — the engineer's weekly
/// grid for the week beginning on `week` (the Monday), with any logged hours.
/// Missing/malformed params are a 400; a DB failure is a 500.
pub fn handle_read(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case read_params(req) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(engineer_id, week_start)) ->
      read_form_response(ctx, engineer_id, week_start)
  }
}

fn read_params(request: wisp.Request) -> Result(#(Int, Date), String) {
  use engineer_id <- result.try(int_param(request, "engineer"))
  use week_start <- result.map(request.date_from_query(request, "week"))
  #(engineer_id, week_start)
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
  week_start: Date,
) -> wisp.Response {
  case timesheet.form_week(ctx, engineer_id, week_start) {
    Ok(week) -> response.json_response(codecs.encode_timesheet_week(week))
    Error(_) -> wisp.internal_server_error()
  }
}
