//// Domain: the leave aggregate — an engineer on leave of a kind over a period,
//// contained by their employment. `command.route` destructures the leave command
//// and calls the operation here with its already-narrowed fields; the operation
//// returns the audit entry and the `Fact`s it records, and `command.dispatch`
//// records them (through `repository`) in ONE transaction. No HTTP — never imports
//// `wisp`.
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
import shared/command.{LeaveCommand} as gateway
import shared/leave/command.{type LeaveCommand, TakeLeave}
import tempo/server/fact.{type Recorded, Recorded}
import tempo/server/operation.{
  type OperationError, Event, InsufficientLeaveBalance,
}
import tempo/server/sql

/// Route a leave command to its operation, returning the audit entry and the facts
/// it records. Exhaustive over `LeaveCommand`.
pub fn route(
  conn: pog.Connection,
  command: LeaveCommand,
) -> Result(Recorded, OperationError) {
  case command {
    TakeLeave(engineer_id:, kind:, valid_from:, valid_to:) ->
      take_leave(conn, command, engineer_id:, kind:, valid_from:, valid_to:)
  }
}

/// Record an engineer on leave of a kind over `[valid_from, valid_to)`, with the
/// journal entry — once the balance guard passes.
pub fn take_leave(
  conn: pog.Connection,
  command: LeaveCommand,
  engineer_id engineer_id: Int,
  kind kind: String,
  valid_from valid_from: Date,
  valid_to valid_to: Date,
) -> Result(Recorded, OperationError) {
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
        payload: gateway.encode_command(LeaveCommand(command)),
      ),
      facts: [
        fact.EngineerOnLeave(
          engineer_id: fact.EngineerId(engineer_id),
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
///
/// Locks the engineer anchor (`FOR UPDATE`) BEFORE reading the balance, so two
/// concurrent leave requests for the same engineer are serialized (issue #2): the
/// second blocks until the first commits, then reads the now-reduced balance — the
/// invariant has no database backstop, so without this lock both could over-grant
/// under READ COMMITTED.
fn guard_balance(
  conn: pog.Connection,
  engineer_id: Int,
  kind: String,
  valid_from: Date,
  valid_to: Date,
) -> Result(Nil, OperationError) {
  use _ <- operation.try(sql.engineer_lock(conn, engineer_id))
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
