//// Web: GET /api/payroll?from=&to= handler — the persisted payroll run for a
//// period. Parse the two dates, call the domain, encode the result. Imports
//// `wisp` (it owns the HTTP shape) but never `sql` — it talks to the domain
//// `finance_query` module, which already speaks shared types.
////
//// `from`/`to` bound the period `[from, to)` (the caller passes a month). A
//// missing/malformed date is a 400; a database failure is a 500.

import gleam/http
import gleam/result
import gleam/time/calendar.{type Date}
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/finance_query
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/payroll?from=YYYY-MM-DD&to=YYYY-MM-DD — the prorated payment
/// per employed engineer for the period.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case period(req) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(from, to)) ->
      case finance_query.payroll(ctx, from, to) {
        Ok(run) -> response.json_response(codecs.encode_payroll(run))
        Error(_) -> wisp.internal_server_error()
      }
  }
}

fn period(request: wisp.Request) -> Result(#(Date, Date), String) {
  use from <- result.try(request.date_from_query(request, "from"))
  use to <- result.map(request.date_from_query(request, "to"))
  #(from, to)
}
