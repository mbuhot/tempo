//// Domain: the write-model dispatch seam. Every business change is a typed
//// `Command` (defined in `shared`, so the client encodes it and the server
//// decodes the same value), applied through ONE transaction here. No HTTP — this
//// layer never imports `wisp`.
////
//// `dispatch` opens one `pog.transaction`, routes the command to its aggregate
//// handler to get the `Fact`s it records, then hands them to
//// `repository.record_facts` — so the facts and their provenance (the
//// `CommandHandled` journal entry) commit together or not at all. `dispatch_in` is
//// the transaction-free core: it runs on an already-open connection so a test can
//// drive it inside its own rolled-back transaction.
////
//// `route` destructures each `Command` ONCE — the only place the command's shape is
//// matched — and hands each aggregate operation its already-narrowed fields (plus the
//// whole command, opaquely, for the journal payload). The `case` is exhaustive over
//// every variant, so the compiler rejects a new command that has no route arm and
//// there is no catch-all to absorb a mis-route: an unhandled command is a COMPILE
//// error, never a runtime panic. The aggregate owns WHICH facts a command records,
//// and the `repository` owns HOW each is written.

import gleam/result
import pog
import shared/types.{
  type Command, type Event, AllocationCommand, ClientDetailsCommand,
  DraftInvoice, EngagementCommand, EngineerCommand, EngineerDetailsCommand,
  IssueInvoice, LeaveCommand, PayInvoice, ProjectDetailsCommand, RateCardCommand,
  RunPayroll, SalaryCommand, SetProjectRequirement, TimesheetCommand,
}
import tempo/server/allocation
import tempo/server/auth.{type Principal, Forbidden}
import tempo/server/client_details
import tempo/server/context.{type Context}
import tempo/server/engagement
import tempo/server/engineer
import tempo/server/engineer_details
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/invoice
import tempo/server/leave
import tempo/server/operation.{type OperationError}
import tempo/server/payroll
import tempo/server/project_details
import tempo/server/project_requirement
import tempo/server/rate_card
import tempo/server/repository
import tempo/server/salary
import tempo/server/timesheet

/// Apply a command on an authenticated `principal`'s behalf: the authorization
/// gate runs FIRST — keyed on principal + command, ONE place covering all 24
/// commands (issue #6) — and refuses with `Unauthorized` BEFORE any transaction
/// opens, so a denied command never touches the database. When allowed, the
/// `actor` stamped on the journal is the principal's, never the request body. Then
/// open one transaction, route to the aggregate for its audit entry and facts, and
/// record them all (the journal entry then the temporal facts, stamped with its
/// id) — together or not at all. A database rejection is classified into a typed
/// `OperationError`. Returns the persisted journal event (with its minted
/// id/occurred_at).
pub fn dispatch(
  context: Context,
  principal principal: Principal,
  command command: Command,
) -> Result(Event, OperationError) {
  use actor <- result.try(authorize(principal, command))
  let outcome =
    pog.transaction(context.db, fn(conn) { dispatch_in(conn, actor, command) })
  case outcome {
    Ok(event) -> Ok(event)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
    Error(pog.TransactionRolledBack(operation_error)) -> Error(operation_error)
  }
}

/// Consult the authorization gate for this principal + command, mapping a refusal
/// to the web layer's typed `Unauthorized` (a 403). Returns the principal's actor
/// to stamp on the journal when allowed.
fn authorize(
  principal: Principal,
  command: Command,
) -> Result(String, OperationError) {
  case auth.authorize(principal, command) {
    Ok(actor) -> Ok(actor)
    Error(Forbidden(actor:, command:)) ->
      Error(operation.Unauthorized(actor:, command:))
  }
}

/// The transaction-free core of `dispatch`: route the command to its aggregate on
/// the given (already-open) connection for its audit entry and facts, then record
/// them in the SAME connection. The caller owns the transaction — production wraps it
/// in `dispatch`; a test drives it inside its own rolled-back transaction. Returns the
/// persisted journal event; a database rejection is a typed `OperationError`.
pub fn dispatch_in(
  conn: pog.Connection,
  actor: String,
  command: Command,
) -> Result(Event, OperationError) {
  use Recorded(entry:, facts:) <- result.try(route(conn, command))
  repository.record_facts(conn, actor:, entry:, facts:)
}

/// Route a command to its aggregate operation, which returns the audit entry and the
/// facts the command records (recording them is `dispatch`'s job). This is the ONE
/// place the command's shape is matched: each arm destructures the variant and hands
/// the operation its already-narrowed fields, plus the whole `command` for the
/// journal payload (encoded opaquely, never re-matched). The `case` is exhaustive, so
/// a new command with no arm — or a mis-route — is a compile error, not a panic.
fn route(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    EngineerCommand(command) -> engineer.route(conn, command)
    AllocationCommand(command) -> allocation.route(conn, command)
    EngagementCommand(command) -> engagement.route(conn, command)
    LeaveCommand(command) -> leave.route(conn, command)
    TimesheetCommand(command) -> timesheet.route(command)
    EngineerDetailsCommand(command) -> engineer_details.route(command)
    ClientDetailsCommand(command) -> client_details.route(command)
    ProjectDetailsCommand(command) -> project_details.route(command)
    RateCardCommand(command) -> rate_card.route(command)

    SetProjectRequirement(
      project_id:,
      level:,
      quantity:,
      valid_from:,
      valid_to:,
    ) ->
      project_requirement.set_project_requirement(
        command,
        project_id:,
        level:,
        quantity:,
        valid_from:,
        valid_to:,
      )

    SalaryCommand(command) -> salary.route(command)

    DraftInvoice(project_id:, billing_from:, billing_to:) ->
      invoice.draft_invoice(
        conn,
        command,
        project_id:,
        billing_from:,
        billing_to:,
      )
    IssueInvoice(invoice_id:, at:) ->
      invoice.issue_invoice(conn, command, invoice_id:, at:)
    PayInvoice(invoice_id:, at:) ->
      invoice.pay_invoice(conn, command, invoice_id:, at:)

    RunPayroll(period_from:, period_to:) ->
      payroll.run_payroll(conn, command, period_from:, period_to:)
  }
}
