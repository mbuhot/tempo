//// Web: the invoices read handlers — GET /api/invoices (list, ?as_of=) and
//// GET /api/invoices/:id (detail, ?as_of=). Parse the request, call the domain,
//// encode the result. Imports `wisp` (it owns the HTTP shape) but never `sql` —
//// it talks to the domain `finance_query` module, which already speaks shared
//// types.
////
//// Both reads take an `as_of` date (the time slider): the list shows each
//// invoice's status as of that date and the detail shows the same header plus its
//// snapshot lines. A missing/malformed `as_of` is a 400; an unknown invoice id is
//// a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/json
import gleam/time/calendar.{type Date}
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/finance_query
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/invoices?as_of=YYYY-MM-DD — the invoices table, each row with
/// its status as of the date and its line total.
pub fn handle_list(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case finance_query.list_invoices(ctx, as_of) {
        Ok(invoices) ->
          response.json_response(json.array(invoices, codecs.encode_invoice))
        Error(_) -> wisp.internal_server_error()
      }
  }
}

/// Handle GET /api/invoices/:id?as_of=YYYY-MM-DD — one invoice's header (status as
/// of the date, total) plus its snapshot lines. A non-integer id is a 400, an
/// unknown id a 404.
pub fn handle_detail(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid invoice id '" <> id_segment <> "'")
    Ok(invoice_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) -> detail_response(ctx, invoice_id, as_of)
      }
  }
}

fn detail_response(
  ctx: Context,
  invoice_id: Int,
  as_of: Date,
) -> wisp.Response {
  case finance_query.invoice_detail(ctx, invoice_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(codecs.encode_invoice_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}
