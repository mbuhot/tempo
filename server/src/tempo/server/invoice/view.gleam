//// Domain: the invoice READ queries (FR-F1/FR-F4). Each function runs a Squirrel
//// query and maps the rows to the shared invoice read types the client renders.
//// No HTTP — this layer never imports `wisp`; the web handlers reach the database
//// only through these functions. The list and detail reads are straight row→type
//// maps; both read each invoice's status AS OF an as-of date.

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/invoice/view.{
  type Invoice, type InvoiceDetail, type InvoiceLine, Invoice, InvoiceDetail,
  InvoiceLine,
} as _
import tempo/server/context.{type Context}
import tempo/server/sql

/// List every invoice with its status AS OF `as_of` and its line total
/// (FR-F1/FR-F4). Only invoices that have a status covering `as_of` appear —
/// scrubbing the slider before an invoice's billing month drops it, and within
/// the month it reads `draft` until its issue date.
pub fn list_invoices(
  context: Context,
  as_of: Date,
) -> Result(List(Invoice), pog.QueryError) {
  use returned <- result.map(sql.invoice_list(context.db, as_of))
  list.map(returned.rows, list_row_to_invoice)
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
