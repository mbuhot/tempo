//// Two-connection concurrency tests for the read-modify-write guards (issue #2).
//// The invoice-status transition and the leave-balance check each read current
//// state then write; under READ COMMITTED two concurrent commands can both read
//// the same pre-state, both pass the guard, and both commit — double-paying an
//// invoice or over-granting leave. The fix takes a row lock (`SELECT … FOR UPDATE`
//// on the contended anchor) before reading, so the second command blocks until the
//// first commits, then re-reads the now-changed state and is rejected.
////
//// Unlike the rolled-back tests elsewhere, these MUST commit: the race only exists
//// across committed transactions. They therefore run against `concurrency_pool` —
//// a dedicated, freshly-migrated database — so the committed fixtures never reach
//// the shared seed the rest of the suite reads. Each test commits a fixture, fires
//// two genuinely concurrent `command.dispatch` calls (each on its own pooled
//// connection, in its own process), and asserts exactly one wins and the other
//// fails with the typed error.

import concurrency_pool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar.{Date, July, June}
import pog
import shared/types.{
  type Command, type Event, InvoiceCommand, LeaveCommand, PayInvoice, TakeLeave,
}
import tempo/server/auth.{Admin, Principal}
import tempo/server/command
import tempo/server/operation.{
  type OperationError, InsufficientLeaveBalance, InvalidValue,
}

/// The principal the race commands dispatch as: actor "racer" with the `Admin`
/// role, so a financial command (PayInvoice) passes the authorization gate.
const racer = Principal(actor: "racer", role: Admin)

/// The pair of outcomes from a race, in launch order.
type Outcomes =
  #(Result(Event, OperationError), Result(Event, OperationError))

/// Dispatch two commands concurrently, each in its own transaction on its own
/// pooled connection, and collect both outcomes in launch order. Each runs in a
/// spawned process and reports back through a subject the test owns, so both
/// transactions are open at once and genuinely contend on the locked row.
fn race(first: Command, second: Command) -> Outcomes {
  let mailbox = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(mailbox, #(
        0,
        command.dispatch(concurrency_pool.ctx(), racer, first),
      ))
    })
  let _ =
    process.spawn(fn() {
      process.send(mailbox, #(
        1,
        command.dispatch(concurrency_pool.ctx(), racer, second),
      ))
    })
  let assert Ok(one) = process.receive(mailbox, 5000)
  let assert Ok(other) = process.receive(mailbox, 5000)
  let sorted = list.sort([one, other], fn(a, b) { int.compare(a.0, b.0) })
  let assert [#(_, first_result), #(_, second_result)] = sorted
  #(first_result, second_result)
}

/// How many of the two race outcomes succeeded.
fn winners(outcomes: Outcomes) -> Int {
  [outcomes.0, outcomes.1]
  |> list.filter(result.is_ok)
  |> list.length
}

/// The losing outcome (the one that errored) of a race won by exactly one.
fn loser(outcomes: Outcomes) -> Result(Event, OperationError) {
  case outcomes.0 {
    Ok(_) -> outcomes.1
    Error(_) -> outcomes.0
  }
}

/// Run a parameterless statement on the dedicated pool.
fn commit(sql: String) -> Nil {
  let assert Ok(_) = pog.query(sql) |> pog.execute(on: concurrency_pool.db())
  Nil
}

// --- invoice: two concurrent PayInvoice -------------------------------------

// A fixture invoice already `issued` over [2026-06-01, ∞). Two concurrent
// PayInvoice on the same day must not both pay it: exactly one wins (records
// `paid`), the other re-reads the now-`paid` status and is rejected as
// InvalidValue. The invoice anchor (id 90001) is well clear of the seed range.
pub fn concurrent_pay_invoice_only_one_wins_test() {
  commit("INSERT INTO invoice (id) VALUES (90001)")
  commit(
    "INSERT INTO invoice_status (invoice_id, status, status_during) VALUES "
    <> "(90001, 'issued', daterange('2026-06-01', NULL, '[)'))",
  )

  let pay =
    InvoiceCommand(PayInvoice(invoice_id: 90_001, at: Date(2026, June, 1)))
  let outcomes = race(pay, pay)

  assert winners(outcomes) == 1
  assert loser(outcomes) == Error(InvalidValue)
}

// --- leave: two concurrent TakeLeave ----------------------------------------

// Priya (engineer 1) has ~56.5 days annual balance on return at 2026-07-25 — enough
// for ONE 40-day request (40 ≤ 56.5) but not two (80 > 56.5). Two concurrent
// requests for the SAME 40-day period are checked against the SAME balance, so under
// READ COMMITTED both could read ~56.5, both pass, and both commit (over-grant). With
// the engineer-anchor lock, the second blocks until the first commits, re-reads the
// now-reduced balance (~16.5 < 40), and is rejected as InsufficientLeaveBalance — by
// the balance guard, before the leave_no_overlap PK is even reached.
pub fn concurrent_take_leave_only_one_wins_test() {
  let take =
    LeaveCommand(TakeLeave(
      1,
      "annual",
      Date(2026, June, 15),
      Date(2026, July, 25),
    ))
  let outcomes = race(take, take)

  assert winners(outcomes) == 1
  let assert Error(InsufficientLeaveBalance(kind:, ..)) = loser(outcomes)
  assert kind == "annual"
}
