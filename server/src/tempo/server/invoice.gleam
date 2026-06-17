//// Domain: the invoice aggregate — a per-project, per-month invoice whose lines are
//// snapshotted at draft and whose status (draft → issued → paid) is a temporal fact.
//// `handle` matches the invoice commands, does ONLY their temporal writes on the
//// in-transaction connection, classifies any database rejection, and returns the
//// journal event(s) it produced; `command.dispatch` owns the transaction and
//// persists those events. No HTTP — never imports `wisp`.
////
//// `DraftInvoice` is an Assert that also computes its lines: mint the invoice
//// identity, open `draft` status, then snapshot one `invoice_line` per (engineer,
//// level) who worked the project that month, at the CONTRACT-agreed rate
//// (`invoice_billing_lines` resolves `rate_card` as of the contract's signing date,
//// FR-F2 — not the billing month). `IssueInvoice`/`PayInvoice` are temporal status
//// Changes carrying real domain logic: read the status covering `at`, GUARD that it
//// is the expected predecessor (`draft → issued`, `issued → paid`) else reject the
//// out-of-order transition as `InvalidValue`, then cap the current status and open
//// the next (the Change pattern). The `invoice_status_no_overlap` exclusion is the
//// database backstop behind the guard.

import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, DraftInvoice, IssueInvoice, PayInvoice}
import tempo/server/operation.{
  type Event, type OperationError, Event, InvalidValue,
}
import tempo/server/sql

/// Apply an invoice-aggregate command: run its temporal writes on the
/// in-transaction connection, classify any database rejection (or reject an
/// out-of-order status transition as `InvalidValue`), and on success return the
/// single journal event it produced. Only the invoice commands reach here (the
/// dispatch `route` guarantees it); any other variant is a no-op.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(List(Event), OperationError) {
  let written = case command {
    DraftInvoice(project_id:, billing_from:, billing_to:) ->
      draft_invoice(conn, project_id, billing_from, billing_to)
      |> result.map_error(operation.classify)
    IssueInvoice(invoice_id:, at:) ->
      transition(conn, invoice_id, from: "draft", to: "issued", at: at)
    PayInvoice(invoice_id:, at:) ->
      transition(conn, invoice_id, from: "issued", to: "paid", at: at)
    _ -> Ok(Nil)
  }
  case written {
    Error(operation_error) -> Error(operation_error)
    Ok(Nil) -> Ok(events(command))
  }
}

/// Draft an invoice: mint the identity, open its `draft` status from the start of
/// the billing month, compute the contract-agreed lines for the month, and insert
/// each — all threaded through the minted id. The status opens at `billing_from`
/// so an as-of query within or after the month reads `draft` (FR-F4).
fn draft_invoice(
  conn: pog.Connection,
  project_id: Int,
  billing_from: Date,
  billing_to: Date,
) -> Result(Nil, pog.QueryError) {
  use created <- result.try(sql.invoice_create(
    conn,
    project_id,
    billing_from,
    billing_to,
  ))
  let invoice_id = case created.rows {
    [row, ..] -> row.id
    [] -> 0
  }
  use _ <- result.try(sql.invoice_status_open(
    conn,
    invoice_id,
    "draft",
    billing_from,
  ))
  use lines <- result.try(sql.invoice_billing_lines(
    conn,
    project_id,
    billing_from,
    billing_to,
  ))
  insert_lines(conn, invoice_id, lines.rows)
}

/// Insert each computed billing line for the drafted invoice, in order. Each line
/// carries its engineer, level, the contract-agreed day_rate, the
/// allocation-weighted days, and amount = days × day_rate (all from
/// `invoice_billing_lines`).
fn insert_lines(
  conn: pog.Connection,
  invoice_id: Int,
  lines: List(sql.InvoiceBillingLinesRow),
) -> Result(Nil, pog.QueryError) {
  case lines {
    [] -> Ok(Nil)
    [line, ..rest] -> {
      use _ <- result.try(sql.invoice_line_insert(
        conn,
        invoice_id,
        line.engineer_id,
        line.level,
        line.day_rate,
        line.days,
        line.amount,
      ))
      insert_lines(conn, invoice_id, rest)
    }
  }
}

/// Move an invoice's status `from → to` at `at` (the Change pattern, with a guard).
/// Read the status covering `at`; GUARD it equals the expected predecessor — an
/// out-of-order transition (e.g. paying a draft, or re-issuing) is rejected as
/// `InvalidValue`, not silently applied. Then cap the current status at `at` and
/// open the next from `at`; the `invoice_status_no_overlap` exclusion is the
/// database backstop.
fn transition(
  conn: pog.Connection,
  invoice_id: Int,
  from from: String,
  to to: String,
  at at: Date,
) -> Result(Nil, OperationError) {
  use _ <- result.try(validate_invoice_status(conn, invoice_id, from, at))
  use _ <- operation.try(sql.invoice_status_close(conn, invoice_id, at))
  use _ <- operation.try(sql.invoice_status_open(conn, invoice_id, to, at))
  Ok(Nil)
}

/// Guard that the invoice's status covering `at` is exactly `expected` — the
/// predecessor the transition requires. An out-of-order transition (paying a
/// draft, re-issuing an issued invoice) is rejected as `InvalidValue`, not
/// silently applied; the `invoice_status_no_overlap` exclusion is the database
/// backstop behind it.
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

/// The journal event(s) an applied invoice command produces.
fn events(command: Command) -> List(Event) {
  case command {
    DraftInvoice(project_id:, billing_from:, billing_to:) -> [
      Event(
        operation: "draft_invoice",
        summary: "Draft invoice for project "
          <> int.to_string(project_id)
          <> " over "
          <> operation.span(billing_from, billing_to),
        payload: codecs.encode_command(command),
      ),
    ]
    IssueInvoice(invoice_id:, at:) -> [
      Event(
        operation: "issue_invoice",
        summary: "Issue invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: codecs.encode_command(command),
      ),
    ]
    PayInvoice(invoice_id:, at:) -> [
      Event(
        operation: "pay_invoice",
        summary: "Pay invoice "
          <> int.to_string(invoice_id)
          <> " on "
          <> operation.iso(at),
        payload: codecs.encode_command(command),
      ),
    ]
    _ -> []
  }
}
