//// Domain: the write-model dispatch seam. Every business change is a typed
//// `Command` (defined in `shared`, so the client encodes it and the server
//// decodes the same value), applied through ONE transaction here. No HTTP — this
//// layer never imports `wisp`.
////
//// `dispatch` opens one `pog.transaction`, routes the command to its aggregate
//// handler, then persists each journal event the handler emits (`event.append`) —
//// so the facts and their provenance commit together or not at all. `dispatch_in`
//// is the transaction-free core: it runs on an already-open connection so a test
//// can drive it inside its own rolled-back transaction.
////
//// `route` carries the WHOLE command to its aggregate `handle` — no destructuring,
//// no event building here; the aggregate owns its temporal writes, its summaries,
//// and its `OperationError` classification (which lives in the `operation` leaf).

import gleam/list
import gleam/result
import pog
import shared/types.{
  type Command, type Event, AdjustRateForPortion, AssignToProject,
  ChangeAllocationFraction, DraftInvoice, IssueInvoice, LogTimesheet, LogWeek,
  OnboardEngineer, PayInvoice, Promote, ReviseRateCard, RollOff, RunPayroll,
  SetSalary, SignContract, StartProject, TakeLeave, TerminateEmployment,
  UpdateBankingDetails, UpdateClientProfile, UpdateContactDetails,
  UpdateEmergencyContact, UpdateProjectPlan, UpdateProjectProfile,
}
import tempo/server/allocation
import tempo/server/client_details
import tempo/server/context.{type Context}
import tempo/server/engagement
import tempo/server/engineer
import tempo/server/engineer_details
import tempo/server/event
import tempo/server/invoice
import tempo/server/leave
import tempo/server/operation.{type Event as JournalEvent, type OperationError}
import tempo/server/payroll
import tempo/server/project_details
import tempo/server/rate_card
import tempo/server/salary
import tempo/server/timesheet

/// Apply a command: open one transaction, route to the aggregate, and persist
/// every journal event it emits — facts and journal commit together or roll back
/// together. A database rejection is classified into a typed `OperationError`.
/// Returns the persisted events (with their minted id/occurred_at).
pub fn dispatch(
  context: Context,
  actor actor: String,
  command command: Command,
) -> Result(List(Event), OperationError) {
  let outcome =
    pog.transaction(context.db, fn(conn) { dispatch_in(conn, actor, command) })
  case outcome {
    Ok(events) -> Ok(events)
    Error(pog.TransactionQueryError(query_error)) ->
      Error(operation.classify(query_error))
    Error(pog.TransactionRolledBack(operation_error)) -> Error(operation_error)
  }
}

/// The transaction-free core of `dispatch`: route the command to its aggregate on
/// the given (already-open) connection, then persist each emitted journal event in
/// the SAME connection. The caller owns the transaction — production wraps it in
/// `dispatch`; a test drives it inside its own rolled-back transaction. Returns
/// the persisted events; a database rejection is a typed `OperationError`.
pub fn dispatch_in(
  conn: pog.Connection,
  actor: String,
  command: Command,
) -> Result(List(Event), OperationError) {
  case route(conn, command) {
    Error(operation_error) -> Error(operation_error)
    Ok(events) -> persist(conn, actor, events)
  }
}

/// Persist each handler-emitted journal event in order, collecting the rows the
/// database minted (id + occurred_at). A `pog.QueryError` from the append is
/// classified into a typed `OperationError`.
fn persist(
  conn: pog.Connection,
  actor: String,
  events: List(JournalEvent),
) -> Result(List(Event), OperationError) {
  list.try_map(events, fn(journal_event) {
    event.append(conn, actor:, event: journal_event)
    |> result.map_error(operation.classify)
  })
}

/// Route a command to its aggregate handler (the temporal writes plus the journal
/// event(s) it emits — persisting them is `dispatch`'s job). Each arm groups the
/// variants one aggregate owns via alternative patterns and hands the WHOLE
/// command to that aggregate's `handle`.
fn route(
  conn: pog.Connection,
  command: Command,
) -> Result(List(JournalEvent), OperationError) {
  case command {
    OnboardEngineer(..) | Promote(..) | TerminateEmployment(..) ->
      engineer.handle(conn, command)

    UpdateContactDetails(..)
    | UpdateBankingDetails(..)
    | UpdateEmergencyContact(..) -> engineer_details.handle(conn, command)

    UpdateClientProfile(..) -> client_details.handle(conn, command)

    UpdateProjectProfile(..) | UpdateProjectPlan(..) ->
      project_details.handle(conn, command)

    AssignToProject(..) | ChangeAllocationFraction(..) | RollOff(..) ->
      allocation.handle(conn, command)

    ReviseRateCard(..) | AdjustRateForPortion(..) ->
      rate_card.handle(conn, command)

    SignContract(..) | StartProject(..) -> engagement.handle(conn, command)

    TakeLeave(..) -> leave.handle(conn, command)

    LogTimesheet(..) | LogWeek(..) -> timesheet.handle(conn, command)

    SetSalary(..) -> salary.handle(conn, command)

    DraftInvoice(..) | IssueInvoice(..) | PayInvoice(..) ->
      invoice.handle(conn, command)

    RunPayroll(..) -> payroll.handle(conn, command)
  }
}
