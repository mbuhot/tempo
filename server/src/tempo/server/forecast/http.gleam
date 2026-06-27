//// Web: GET /api/forecast?as_of= handler — the forward P&L from committed demand.
//// Parse the as-of date, call the domain, encode the result. Imports `wisp` (it
//// owns the HTTP shape) but never `sql` — it talks to the domain `forecast/view`
//// read module, which already speaks shared types.
////
//// `as_of` is the first month of the forecast window; the series runs to the cliff
//// (the last day any requirement or allocation runs). A missing/malformed `as_of`
//// is a 400; a database failure is a 500.

import gleam/http
import shared/forecast/view as forecast_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/forecast/table as forecast_table
import tempo/server/forecast/view as forecast_read
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
      case forecast_read.forecast(ctx, as_of) {
        Ok(forecast) ->
          response.json_response(forecast_view.encode_forecast(forecast))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/forecast/table?as_of=&filter.*=&sort=&page_size=&cursor= — the
/// generic data-table read for the forecast: the schema the client renders from plus
/// one filtered, sorted, paged slice of the calendar-month rows from the as-of month
/// to the demand cliff. Filters/sort/page are parsed from the query params against
/// the table's filter schema; `page_size` is clamped to the server bound. A
/// missing/malformed `as_of` is a 400; a database failure is a 500.
pub fn handle_table(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) -> {
      let applied =
        query.from_params(
          wisp.get_query(req),
          forecast_table.filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case forecast_table.forecast_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}
