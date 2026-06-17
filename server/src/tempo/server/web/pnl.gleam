//// Web: GET /api/pnl?as_of= handler — the P&L statement for a date. Parse the
//// as-of date, call the domain, encode the result. Imports `wisp` (it owns the
//// HTTP shape) but never `sql` — it talks to the domain `finance_query` module,
//// which already speaks shared types.
////
//// `as_of` selects the month (the month containing the date) and the year-to-date
//// window; the domain computes the totals and the per-engineer breakdown. A
//// missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/finance_query
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/pnl?as_of=YYYY-MM-DD — month/YTD revenue/cost/profit totals
/// plus the per-engineer revenue/cost/profit/margin/utilization rows.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case finance_query.pnl(ctx, as_of) {
        Ok(statement) -> response.json_response(codecs.encode_pnl(statement))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
