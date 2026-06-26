//// Run independent computations concurrently. `start` spawns a thunk on its own
//// linked process and hands back a subject carrying its eventual result; `await`
//// blocks for that result, panicking if it does not arrive within the timeout (a
//// hung computation is a bug — the crash surfaces as a 500 under
//// `wisp.rescue_crashes`). `gleam_otp` no longer ships a `task` module, so this is
//// the minimal spawn-and-reply primitive that stands in for `task.async`/`await`.
////
//// Nothing here is database-specific: `work` is any `fn() -> value`. Fan a handful
//// of independent reads out with `start`, then `await` each — the wall-clock cost
//// becomes the slowest one rather than their sum.

import gleam/erlang/process.{type Subject}
import pog

/// A handle on a query running concurrently on its own process: the subject yields
/// the query's `Result(pog.Returned(row), pog.QueryError)` once. Annotating a
/// `start`ed query subject with this keeps its row type concrete, so the awaited
/// value can be field-accessed without the generic spawn/receive round-trip
/// erasing it.
pub type AsyncQuery(row) =
  Subject(Result(pog.Returned(row), pog.QueryError))

/// Spawn `work` on a linked process; the returned subject yields its result once.
pub fn start(work: fn() -> value) -> Subject(value) {
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, work()) })
  reply
}

/// Block until the spawned work replies, or panic if it does not within `timeout`
/// milliseconds.
pub fn await(subject: Subject(value), timeout: Int) -> value {
  let assert Ok(value) = process.receive(subject, timeout)
  value
}
