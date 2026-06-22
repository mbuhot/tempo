//// Domain: the invoice aggregate — a per-project, per-month invoice whose lines are
//// snapshotted at draft and whose status (draft → issued → paid) is a temporal fact.
//// `handle` routes each invoice command to a named operation that returns the
//// `Fact`s it records; `command.dispatch` records them (through `repository`) and
//// persists the journal in ONE transaction. No HTTP — never imports `wisp`.
////
//// `draft_invoice` reserves the invoice id, computes its lines (one per (engineer,
//// level) who worked the project that month, at the CONTRACT-agreed rate —
//// `invoice_billing_lines` resolves `rate_card` as of the contract's signing date,
//// FR-F2), and records the anchor, subject, opening `draft` status, and one line per
//// row. `issue_invoice`/`pay_invoice` guard that the status in effect at `at` is the
//// expected predecessor (else `InvalidValue`) then record the next `InvoiceInStatus`
//// (the repository caps the prior status where the next begins).

import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, DraftInvoice, IssueInvoice, PayInvoice}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{type OperationError, Event, InvalidValue}
import tempo/server/repository
import tempo/server/sql

/// Apply an invoice-aggregate command: route it to its named operation, which
/// returns the audit entry and facts it records. The dispatch `route` only ever
/// sends invoice commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    DraftInvoice(..) -> draft_invoice(conn, command)
    IssueInvoice(..) -> issue_invoice(conn, command)
    PayInvoice(..) -> pay_invoice(conn, command)
    _ ->
      panic as "invoice.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Draft an invoice: reserve the id, compute the contract-agreed lines for the
/// month, and record the anchor, subject, opening `draft` status (from
/// `billing_from`, so an as-of query within or after the month reads `draft`,
/// FR-F4), and one line per row, with the journal entry.
fn draft_invoice(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert DraftInvoice(project_id:, billing_from:, billing_to:) = command
  use invoice_id <- result.try(repository.create_invoice(conn))
  let fact.InvoiceId(id) = invoice_id
  use lines <- operation.try(sql.invoice_billing_lines(
    conn,
    project_id,
    billing_from,
    billing_to,
  ))
  let line_facts =
    list.map(lines.rows, fn(line) {
      fact.InvoiceLine(
        invoice_id:,
        engineer_id: fact.EngineerId(line.engineer_id),
        level: line.level,
        day_rate: line.day_rate,
        days: line.days,
        amount: line.amount,
      )
    })
  Ok(Recorded(
    entry: Event(
      operation: "draft_invoice",
      summary: "Draft invoice for project "
        <> int.to_string(project_id)
        <> " (invoice "
        <> int.to_string(id)
        <> ") over "
        <> operation.span(billing_from, billing_to),
      payload: codecs.encode_command(command),
    ),
    facts: list.flatten([
      [
        fact.InvoiceSubject(
          invoice_id:,
          project_id: fact.ProjectId(project_id),
          from: billing_from,
          to: billing_to,
        ),
        fact.InvoiceInStatus(invoice_id:, status: "draft", from: billing_from),
      ],
      line_facts,
    ]),
  ))
}

/// Issue an invoice: guard it is currently `draft` at `at`, then record `issued`
/// from `at`, with the journal entry.
fn issue_invoice(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert IssueInvoice(invoice_id:, at:) = command
  use _ <- result.try(validate_invoice_status(conn, invoice_id, "draft", at))
  Ok(
    Recorded(
      entry: Event(
        operation: "issue_invoice",
        summary: "Issue invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.InvoiceInStatus(
          invoice_id: fact.InvoiceId(invoice_id),
          status: "issued",
          from: at,
        ),
      ],
    ),
  )
}

/// Pay an invoice: guard it is currently `issued` at `at`, then record `paid` from
/// `at`, with the journal entry.
fn pay_invoice(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert PayInvoice(invoice_id:, at:) = command
  use _ <- result.try(validate_invoice_status(conn, invoice_id, "issued", at))
  Ok(
    Recorded(
      entry: Event(
        operation: "pay_invoice",
        summary: "Pay invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.InvoiceInStatus(
          invoice_id: fact.InvoiceId(invoice_id),
          status: "paid",
          from: at,
        ),
      ],
    ),
  )
}

/// Guard that the invoice's status covering `at` is exactly `expected` — the
/// predecessor the transition requires. An out-of-order transition (paying a draft,
/// re-issuing an issued invoice) is rejected as `InvalidValue`, not silently applied.
fn validate_invoice_status(
  conn: pog.Connection,
  invoice_id: Int,
  expected: String,
  at: Date,
) -> Result(Nil, OperationError) {
  use current <- operation.try(sql.invoice_status_current(conn, invoice_id, at))
  case list.map(current.rows, fn(row) { row.status }) == [expected] {
    True -> Ok(Nil)
    False -> Error(InvalidValue)
  }
}
