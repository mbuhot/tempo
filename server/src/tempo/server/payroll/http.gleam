//// Web: GET /api/payroll?from=&to= handler — the persisted payroll run for a
//// period. Parse the two dates, call the domain, encode the result. Imports
//// `wisp` (it owns the HTTP shape) but never `sql` — it talks to the domain
//// `payroll/view` read module, which already speaks shared types.
////
//// `from`/`to` bound the period `[from, to)` (the caller passes a month). A
//// missing/malformed date is a 400; a database failure is a 500.

import gleam/http
import gleam/result
import gleam/time/calendar.{type Date}
import shared/payroll/view as payroll_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/payroll/table as payroll_table
import tempo/server/payroll/view as payroll_read
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
      case payroll_read.payroll(ctx, from, to) {
        Ok(run) -> response.json_response(payroll_view.encode_payroll(run))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/payroll/table?from=&to=&mode=&filter.*=&sort=&page_size=&cursor=
/// — the generic data-table read for the payroll panel: the schema for the requested
/// `mode` (preview/reconciled/variance) plus one filtered, sorted, paged slice of
/// the engineer-total rows, each carrying its per-level segment sub-rows as children.
/// Filters/sort/page are parsed from the query params against the mode's filter
/// schema; `page_size` is clamped to the server bound. A missing/malformed date is a
/// 400; a database failure is a 500.
pub fn handle_table(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case period(req) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(from, to)) -> {
      let mode =
        payroll_table.mode_from_string(request.optional_string_from_query(
          req,
          "mode",
        ))
      let applied =
        query.from_params(
          wisp.get_query(req),
          payroll_table.filter_schema(mode),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case payroll_table.payroll_table(ctx, from, to, mode, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}

fn period(request: wisp.Request) -> Result(#(Date, Date), String) {
  use from <- result.try(request.date_from_query(request, "from"))
  use to <- result.map(request.date_from_query(request, "to"))
  #(from, to)
}
