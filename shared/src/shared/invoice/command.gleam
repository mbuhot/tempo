//// The invoice aggregate's write command type and its JSON codec (the draft and the
//// issued/paid lifecycle transitions). `encode` tags each variant by its `op`;
//// `decoder` returns the field decoder for an `op` this aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type InvoiceCommand {
  /// Draft an invoice for a project's billing month, computing its lines at the
  /// contract-agreed rate (`rate_card` as of the contract's signing date).
  DraftInvoice(project_id: Int, billing_from: Date, billing_to: Date)
  /// Transition an invoice `draft -> issued` at a date (a temporal status change).
  IssueInvoice(invoice_id: Int, at: Date)
  /// Transition an invoice `issued -> paid` at a date (a temporal status change).
  PayInvoice(invoice_id: Int, at: Date)
}

/// Encode an `InvoiceCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: InvoiceCommand) -> Json {
  case command {
    DraftInvoice(project_id:, billing_from:, billing_to:) ->
      json.object([
        #("op", json.string("draft_invoice")),
        #("project_id", json.int(project_id)),
        #("billing_from", encode_date(billing_from)),
        #("billing_to", encode_date(billing_to)),
      ])
    IssueInvoice(invoice_id:, at:) ->
      json.object([
        #("op", json.string("issue_invoice")),
        #("invoice_id", json.int(invoice_id)),
        #("at", encode_date(at)),
      ])
    PayInvoice(invoice_id:, at:) ->
      json.object([
        #("op", json.string("pay_invoice")),
        #("invoice_id", json.int(invoice_id)),
        #("at", encode_date(at)),
      ])
  }
}

/// The field decoder for an invoice `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(InvoiceCommand), Nil) {
  case op {
    "draft_invoice" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use billing_from <- decode.field("billing_from", date_decoder())
        use billing_to <- decode.field("billing_to", date_decoder())
        decode.success(DraftInvoice(project_id:, billing_from:, billing_to:))
      })
    "issue_invoice" ->
      Ok({
        use invoice_id <- decode.field("invoice_id", decode.int)
        use at <- decode.field("at", date_decoder())
        decode.success(IssueInvoice(invoice_id:, at:))
      })
    "pay_invoice" ->
      Ok({
        use invoice_id <- decode.field("invoice_id", decode.int)
        use at <- decode.field("at", date_decoder())
        decode.success(PayInvoice(invoice_id:, at:))
      })
    _ -> Error(Nil)
  }
}
