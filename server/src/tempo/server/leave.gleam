//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. `handle` routes the leave command to a named
//// operation that returns the audit entry and the `Fact`s it records;
//// `command.dispatch` records them (through `repository`) in ONE transaction. No
//// HTTP — never imports `wisp`.
////
//// `take_leave` first guards the leave balance: for a kind WITH a policy, the
//// accrued-minus-taken balance on return (`leave_check` as of `valid_to`) must cover
//// the requested days, else `InsufficientLeaveBalance`. A kind with no policy is
//// unlimited. It then records a bounded `EngineerOnLeave` fact; the
//// `leave_within_employment` PERIOD FK is the database backstop for leave outside
//// the engineer's employment.

import gleam/int
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/codecs
import shared/types.{type Command, TakeLeave}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{
  type OperationError, Event, InsufficientLeaveBalance,
}
import tempo/server/sql

/// Apply a leave-aggregate command: route it to its named operation, which returns
/// the audit entry and facts it records. The dispatch `route` only ever sends leave
/// commands here, so any other variant is a routing bug — `panic`.
pub fn handle(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  case command {
    TakeLeave(..) -> take_leave(conn, command)
    _ ->
      panic as "leave.handle: command not owned by this aggregate (dispatch bug)"
  }
}

/// Record an engineer on leave of a kind over `[valid_from, valid_to)`, with the
/// journal entry — once the balance guard passes.
fn take_leave(
  conn: pog.Connection,
  command: Command,
) -> Result(Recorded, OperationError) {
  let assert TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) = command
  use _ <- result.try(guard_balance(
    conn,
    engineer_id,
    kind,
    valid_from,
    valid_to,
  ))
  Ok(
    Recorded(
      entry: Event(
        operation: "take_leave",
        summary: "Engineer "
          <> int.to_string(engineer_id)
          <> " on "
          <> kind
          <> " leave over "
          <> operation.span(valid_from, valid_to),
        payload: codecs.encode_command(command),
      ),
      facts: [
        fact.EngineerOnLeave(
          engineer_id:,
          kind:,
          from: valid_from,
          to: valid_to,
        ),
      ],
    ),
  )
}

/// Reject the leave when the kind is policied and the balance on return is short of
/// the days requested; a kind with no policy is unlimited and always passes.
fn guard_balance(
  conn: pog.Connection,
  engineer_id: Int,
  kind: String,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, OperationError) {
  use checked <- operation.try(sql.leave_check(
    conn,
    engineer_id,
    kind,
    valid_from,
    valid_to,
  ))
  let assert [check] = checked.rows
  case check.policied && check.available <. check.requested {
    True ->
      Error(InsufficientLeaveBalance(
        kind:,
        available: check.available,
        requested: check.requested,
      ))
    False -> Ok(Nil)
  }
}
