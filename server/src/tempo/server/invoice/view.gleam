//// Domain: the invoice READ queries (FR-F1/FR-F4). Each function runs a Squirrel
//// query and maps the rows to the shared invoice read types the client renders.
//// No HTTP — this layer never imports `wisp`; the web handlers reach the database
//// only through these functions. The list and detail reads are straight row→type
//// maps; both read each invoice's status AS OF an as-of date.

import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/invoice/view.{
  type Invoice, type InvoiceDetail, type InvoiceLine, Invoice, InvoiceDetail,
  InvoiceLine,
} as _
import shared/pagination
import tempo/server/context.{type Context}
import tempo/server/sql
import tempo/server/web/cursor.{type DateIdBound, DateIdBound}

/// List one keyset page of invoices with each row's status AS OF `as_of` and its
/// line total (FR-F1/FR-F4), starting strictly after `after` and at most `limit`
/// rows (issue #12). Returns the page rows plus the `next_cursor` for the following
/// page (`None` on the last page). Only invoices with a status covering `as_of`
/// appear — scrubbing before an invoice's billing month drops it.
///
/// Fetches `limit + 1` rows so the look-ahead row tells `pagination.paginate`
/// whether a further page exists; the order is the SQL's stable
/// (billing_from, id).
pub fn list_invoices(
  context: Context,
  as_of: Date,
  after: DateIdBound,
  limit: Int,
) -> Result(#(List(Invoice), Option(String)), pog.QueryError) {
  let DateIdBound(date:, id:) = after
  use returned <- result.map(sql.invoice_list(context.db, as_of, date, id, limit + 1))
  let #(rows, next_cursor) =
    pagination.paginate(returned.rows, limit, fn(row: sql.InvoiceListRow) {
      cursor.encode_date_id(row.billing_from, row.id)
    })
  #(list.map(rows, list_row_to_invoice), next_cursor)
}

fn list_row_to_invoice(row: sql.InvoiceListRow) -> Invoice {
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status: row.status,
    total: row.total,
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}

/// One invoice's detail (`GET /api/invoices/:id`): the header (status AS OF
/// `as_of`, total) plus its snapshot lines. Returns `Ok(None)` when no invoice
/// has that id, so the handler can answer a 404 rather than a 500.
pub fn invoice_detail(
  context: Context,
  invoice_id: Int,
  as_of: Date,
) -> Result(Result(InvoiceDetail, Nil), pog.QueryError) {
  use header <- result.try(sql.invoice_header(context.db, invoice_id, as_of))
  case header.rows {
    [] -> Ok(Error(Nil))
    [row, ..] -> {
      use lines <- result.map(sql.invoice_lines(context.db, invoice_id))
      Ok(InvoiceDetail(
        invoice: header_row_to_invoice(row),
        lines: list.map(lines.rows, lines_row_to_invoice_line),
      ))
    }
  }
}

fn header_row_to_invoice(row: sql.InvoiceHeaderRow) -> Invoice {
  Invoice(
    id: row.id,
    project: row.project,
    client: row.client,
    billing_from: row.billing_from,
    billing_to: row.billing_to,
    status: row.status,
    total: row.total,
    issued_at: row.issued_at,
    paid_at: row.paid_at,
  )
}

fn lines_row_to_invoice_line(row: sql.InvoiceLinesRow) -> InvoiceLine {
  InvoiceLine(
    engineer: row.engineer,
    level: row.level,
    day_rate: row.day_rate,
    days: row.days,
    amount: row.amount,
  )
}
