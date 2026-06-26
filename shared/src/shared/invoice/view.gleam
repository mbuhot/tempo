//// The invoice read models and their JSON codecs: the invoices-table `Invoice`
//// row, an `InvoiceLine` snapshot line, and the `InvoiceDetail` bundle. Pure
//// Gleam, no target-specific deps, so they round-trip on both ends of the
//// JSON-over-HTTP boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings and
//// money decodes leniently (a whole amount may arrive integer-looking from JS).

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/pagination
import shared/wire

/// One invoice on the invoices-table read model (FR-F1/FR-F4): the durable subject
/// (`id`, `project`, `client`, the `billing_from`..`billing_to` month) plus its
/// `status` *as of* the selected date and its `total` (Σ line amounts). `status`
/// is the lifecycle word ("draft" | "issued" | "paid") covering the as-of date.
/// `issued_at`/`paid_at` are the dates those transitions took effect (the lower
/// bound of the issued/paid status span), each `None` until that transition has
/// happened as of the view — so the UI can show "Issued <date>" / "Paid <date>".
pub type Invoice {
  Invoice(
    id: Int,
    project: String,
    client: String,
    billing_from: Date,
    billing_to: Date,
    status: String,
    total: Money,
    issued_at: Option(Date),
    paid_at: Option(Date),
  )
}

/// One snapshot line of an invoice (FR-F1): the engineer who worked the project in
/// the period, their `level` during the work, the contract-agreed `day_rate`, the
/// allocation-weighted `days`, and `amount = days × day_rate`.
pub type InvoiceLine {
  InvoiceLine(
    engineer: String,
    level: Int,
    day_rate: Money,
    days: Float,
    amount: Money,
  )
}

/// The invoice-detail read model (`GET /api/invoices/:id`): the `invoice` header
/// and its computed `lines`.
pub type InvoiceDetail {
  InvoiceDetail(invoice: Invoice, lines: List(InvoiceLine))
}

/// One keyset page of the invoices list (`GET /api/invoices`): the page's
/// `invoices` (item shape unchanged) plus the opaque `next_cursor` to fetch the
/// following page (`None` on the last page). Issue #12.
pub type InvoicePage {
  InvoicePage(invoices: List(Invoice), next_cursor: Option(String))
}

/// Encode an `Invoice` (one invoices-table row) as a JSON object.
pub fn encode_invoice(invoice: Invoice) -> Json {
  let Invoice(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
    issued_at:,
    paid_at:,
  ) = invoice
  json.object([
    #("id", json.int(id)),
    #("project", json.string(project)),
    #("client", json.string(client)),
    #("billing_from", wire.encode_date(billing_from)),
    #("billing_to", wire.encode_date(billing_to)),
    #("status", json.string(status)),
    #("total", money.encode(total)),
    #("issued_at", wire.encode_option_date(issued_at)),
    #("paid_at", wire.encode_option_date(paid_at)),
  ])
}

/// Decode an `Invoice` from a JSON object.
pub fn invoice_decoder() -> Decoder(Invoice) {
  use id <- decode.field("id", decode.int)
  use project <- decode.field("project", decode.string)
  use client <- decode.field("client", decode.string)
  use billing_from <- decode.field("billing_from", wire.date_decoder())
  use billing_to <- decode.field("billing_to", wire.date_decoder())
  use status <- decode.field("status", decode.string)
  use total <- decode.field("total", money.decoder())
  use issued_at <- decode.field("issued_at", wire.option_date_decoder())
  use paid_at <- decode.field("paid_at", wire.option_date_decoder())
  decode.success(Invoice(
    id:,
    project:,
    client:,
    billing_from:,
    billing_to:,
    status:,
    total:,
    issued_at:,
    paid_at:,
  ))
}

/// Encode an `InvoiceLine` (one snapshot line) as a JSON object.
pub fn encode_invoice_line(line: InvoiceLine) -> Json {
  let InvoiceLine(engineer:, level:, day_rate:, days:, amount:) = line
  json.object([
    #("engineer", json.string(engineer)),
    #("level", json.int(level)),
    #("day_rate", money.encode(day_rate)),
    #("days", json.float(days)),
    #("amount", money.encode(amount)),
  ])
}

/// Decode an `InvoiceLine` from a JSON object.
pub fn invoice_line_decoder() -> Decoder(InvoiceLine) {
  use engineer <- decode.field("engineer", decode.string)
  use level <- decode.field("level", decode.int)
  use day_rate <- decode.field("day_rate", money.decoder())
  use days <- decode.field("days", wire.lenient_float_decoder())
  use amount <- decode.field("amount", money.decoder())
  decode.success(InvoiceLine(engineer:, level:, day_rate:, days:, amount:))
}

/// Encode an `InvoicePage` (one keyset page of the invoices list) to JSON.
pub fn encode_invoice_page(page: InvoicePage) -> Json {
  let InvoicePage(invoices:, next_cursor:) = page
  json.object([
    #("invoices", json.array(invoices, encode_invoice)),
    #("next_cursor", pagination.encode_next_cursor(next_cursor)),
  ])
}

/// Decode an `InvoicePage` from JSON.
pub fn invoice_page_decoder() -> Decoder(InvoicePage) {
  use invoices <- decode.field("invoices", decode.list(invoice_decoder()))
  use next_cursor <- decode.field(
    "next_cursor",
    pagination.next_cursor_decoder(),
  )
  decode.success(InvoicePage(invoices:, next_cursor:))
}

/// Encode an `InvoiceDetail` (the header plus its computed lines) to JSON.
pub fn encode_invoice_detail(detail: InvoiceDetail) -> Json {
  let InvoiceDetail(invoice:, lines:) = detail
  json.object([
    #("invoice", encode_invoice(invoice)),
    #("lines", json.array(lines, encode_invoice_line)),
  ])
}

/// Decode an `InvoiceDetail` from JSON.
pub fn invoice_detail_decoder() -> Decoder(InvoiceDetail) {
  use invoice <- decode.field("invoice", invoice_decoder())
  use lines <- decode.field("lines", decode.list(invoice_line_decoder()))
  decode.success(InvoiceDetail(invoice:, lines:))
}
