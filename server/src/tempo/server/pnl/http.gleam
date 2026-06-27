//// Web: GET /api/pnl?as_of= handler — the P&L statement for a date. Parse the
//// as-of date, call the domain, encode the result. Imports `wisp` (it owns the
//// HTTP shape) but never `sql` — it talks to the domain `pnl/view` read module,
//// which already speaks shared types.
////
//// `as_of` selects the month (the month containing the date) and the year-to-date
//// window; the domain computes the totals and the per-engineer breakdown. A
//// missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/pnl/view as pnl_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/pnl/table as pnl_table
import tempo/server/pnl/view as pnl_read
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
      case pnl_read.pnl(ctx, as_of) {
        Ok(statement) -> response.json_response(pnl_view.encode_pnl(statement))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/pnl/table?as_of=&filter.*=&sort=&page_size=&cursor= — the
/// generic data-table read for the per-engineer P&L: the schema the client renders
/// from plus one filtered, sorted, paged slice of rows for the month containing
/// `as_of`. Filters/sort/page are parsed from the query params against the table's
/// filter schema; `page_size` is clamped to the server bound. A missing/malformed
/// `as_of` is a 400; a database failure is a 500.
pub fn handle_table(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) -> {
      let applied =
        query.from_params(
          wisp.get_query(req),
          pnl_table.filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case pnl_table.pnl_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}
