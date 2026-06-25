//// Web: the invoices read handlers — GET /api/invoices (list, ?as_of=) and
//// GET /api/invoices/:id (detail, ?as_of=). Parse the request, call the domain,
//// encode the result. Imports `wisp` (it owns the HTTP shape) but never `sql` —
//// it talks to the domain `invoice/view` read module, which already speaks shared
//// types.
////
//// Both reads take an `as_of` date (the time slider): the list shows each
//// invoice's status as of that date and the detail shows the same header plus its
//// snapshot lines. A missing/malformed `as_of` is a 400; an unknown invoice id is
//// a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/option
import gleam/result
import gleam/time/calendar.{type Date}
import shared/invoice/view.{InvoicePage} as invoice_view
import tempo/server/context.{type Context}
import tempo/server/invoice/view as invoice_read
import tempo/server/web/cursor.{type DateIdBound}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/invoices?as_of=YYYY-MM-DD&cursor=&limit= — one keyset page of
/// the invoices table (issue #12), each row with its status as of the date and its
/// line total, plus the `next_cursor` for the following page. `cursor` is the
/// opaque token from a prior page's `next_cursor` (absent ⇒ first page); `limit`
/// defaults to the server default and is clamped to the max. A malformed
/// `cursor`/`limit` is a 400.
pub fn handle_list(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let parsed = {
    use as_of <- result.try(request.date_from_query(req, "as_of"))
    use after <- result.try(invoice_cursor(req))
    use limit <- result.map(request.optional_int_from_query(req, "limit"))
    #(as_of, after, context.clamp_limit(option.unwrap(limit, context.default_page_limit)))
  }
  case parsed {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(as_of, after, limit)) ->
      case invoice_read.list_invoices(ctx, as_of, after, limit) {
        Ok(#(invoices, next_cursor)) ->
          response.json_response(
            invoice_view.encode_invoice_page(InvoicePage(
              invoices:,
              next_cursor:,
            )),
          )
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Parse the optional `cursor` query param into the invoice keyset bound: absent ⇒
/// the first-page sentinel, present-and-valid ⇒ its `(billing_from, id)` bound,
/// present-but-malformed ⇒ `Error(detail)` for a 400.
fn invoice_cursor(req: wisp.Request) -> Result(DateIdBound, String) {
  case request.optional_string_from_query(req, "cursor") {
    option.None -> Ok(cursor.date_id_start())
    option.Some(token) ->
      cursor.decode_date_id(token)
      |> result.replace_error("invalid cursor '" <> token <> "'")
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
  case invoice_read.invoice_detail(ctx, invoice_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(invoice_view.encode_invoice_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
