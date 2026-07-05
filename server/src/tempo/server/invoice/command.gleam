//// Domain: the invoice aggregate — a per-project, per-month invoice whose lines are
//// snapshotted at draft and whose status (draft → issued → paid) is a temporal fact.
//// `command.route` destructures each invoice command and calls the matching
//// operation here with its already-narrowed fields; the operation returns the
//// `Fact`s it records, and `command.dispatch` records them (through `repository`)
//// and persists the journal in ONE transaction. No HTTP — never imports `wisp`.
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
import shared/command.{InvoiceCommand} as gateway
import shared/invoice/command.{
  type InvoiceCommand, DraftInvoice, IssueInvoice, PayInvoice,
}
import shared/invoice/status.{type InvoiceStatus, Draft, Issued, Paid}
import shared/money
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/invoice/sql
import tempo/server/operation.{type OperationError, Event, InvalidValue}
import tempo/server/repository

/// Route an invoice command to its operation, returning the audit entry and the
/// facts it records. Exhaustive over `InvoiceCommand`.
pub fn route(
  conn: pog.Connection,
  command: InvoiceCommand,
) -> Result(Recorded, OperationError) {
  case command {
    DraftInvoice(project_id:, billing_from:, billing_to:) ->
      draft_invoice(conn, command, project_id:, billing_from:, billing_to:)
    IssueInvoice(invoice_id:, at:) ->
      issue_invoice(conn, command, invoice_id:, at:)
    PayInvoice(invoice_id:, at:) -> pay_invoice(conn, command, invoice_id:, at:)
  }
}

/// Draft an invoice: reserve the id, compute the contract-agreed lines for the
/// month, and record the anchor, subject, opening `draft` status (from
/// `billing_from`, so an as-of query within or after the month reads `draft`,
/// FR-F4), and one line per row, with the journal entry.
pub fn draft_invoice(
  conn: pog.Connection,
  command: InvoiceCommand,
  project_id project_id: Int,
  billing_from billing_from: Date,
  billing_to billing_to: Date,
) -> Result(Recorded, OperationError) {
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
        day_rate: money.trusted_from_string(line.day_rate),
        days: line.days,
        amount: money.trusted_from_string(line.amount),
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
      payload: gateway.encode_command(InvoiceCommand(command)),
    ),
    facts: list.flatten([
      [
        fact.InvoiceSubject(
          invoice_id:,
          project_id: fact.ProjectId(project_id),
          from: billing_from,
          to: billing_to,
        ),
        fact.InvoiceInStatus(invoice_id:, status: Draft, from: billing_from),
      ],
      line_facts,
    ]),
  ))
}

/// Issue an invoice: guard it is currently `draft` at `at`, then record `issued`
/// from `at`, with the journal entry.
pub fn issue_invoice(
  conn: pog.Connection,
  command: InvoiceCommand,
  invoice_id invoice_id: Int,
  at at: Date,
) -> Result(Recorded, OperationError) {
  use _ <- result.try(validate_invoice_status(conn, invoice_id, Draft, at))
  Ok(
    Recorded(
      entry: Event(
        operation: "issue_invoice",
        summary: "Issue invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: gateway.encode_command(InvoiceCommand(command)),
      ),
      facts: [
        fact.InvoiceInStatus(
          invoice_id: fact.InvoiceId(invoice_id),
          status: Issued,
          from: at,
        ),
      ],
    ),
  )
}

/// Pay an invoice: guard it is currently `issued` at `at`, then record `paid` from
/// `at`, with the journal entry.
pub fn pay_invoice(
  conn: pog.Connection,
  command: InvoiceCommand,
  invoice_id invoice_id: Int,
  at at: Date,
) -> Result(Recorded, OperationError) {
  use _ <- result.try(validate_invoice_status(conn, invoice_id, Issued, at))
  Ok(
    Recorded(
      entry: Event(
        operation: "pay_invoice",
        summary: "Pay invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: gateway.encode_command(InvoiceCommand(command)),
      ),
      facts: [
        fact.InvoiceInStatus(
          invoice_id: fact.InvoiceId(invoice_id),
          status: Paid,
          from: at,
        ),
      ],
    ),
  )
}

/// Guard that the invoice's status covering `at` is exactly `expected` — the
/// predecessor the transition requires. An out-of-order transition (paying a draft,
/// re-issuing an issued invoice) is rejected as `InvalidValue`, not silently applied.
///
/// Locks the invoice anchor (`FOR UPDATE`) BEFORE reading the status, so two
/// concurrent transitions on the same invoice are serialized (issue #2): the second
/// blocks until the first commits, then reads the now-changed status and is rejected
/// — never double-paid under READ COMMITTED.
fn validate_invoice_status(
  conn: pog.Connection,
  invoice_id: Int,
  expected: InvoiceStatus,
  at: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(sql.invoice_lock(conn, invoice_id))
  use current <- operation.try(sql.invoice_status_current(conn, invoice_id, at))
  case
    list.map(current.rows, fn(row) { row.status })
    == [status.to_string(expected)]
  {
    True -> Ok(Nil)
    False -> Error(InvalidValue)
  }
}
