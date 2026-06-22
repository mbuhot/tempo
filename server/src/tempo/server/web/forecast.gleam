//// Web: GET /api/forecast?as_of= handler — the forward P&L from committed demand.
//// Parse the as-of date, call the domain, encode the result. Imports `wisp` (it
//// owns the HTTP shape) but never `sql` — it talks to the domain `finance_query`
//// module, which already speaks shared types.
////
//// `as_of` is the first month of the forecast window; the series runs to the cliff
//// (the last day any requirement or allocation runs). A missing/malformed `as_of`
//// is a 400; a database failure is a 500.

import gleam/http
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/finance_query
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/forecast?as_of=YYYY-MM-DD — one revenue/cost/profit/margin row
/// per calendar month from the as-of month to the cliff.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case finance_query.forecast(ctx, as_of) {
        Ok(forecast) -> response.json_response(codecs.encode_forecast(forecast))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
