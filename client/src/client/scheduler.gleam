//// A minimal timer effect: dispatch a message after a delay. The time rail uses it
//// as an app-layer debounce — every scrub updates the as-of instantly (so the
//// readout tracks the thumb), but the expensive refetch + URL sync is deferred to a
//// settle that fires once the scrub stops. Scheduling is fire-and-forget (no
//// cancellation); a superseded fire is ignored by the shell via a generation token.

import lustre/effect.{type Effect}

/// An effect that dispatches `msg` after `delay_ms` milliseconds (browser
/// `setTimeout`). Multiple `after`s race; the caller distinguishes the live one.
pub fn after(delay_ms: Int, msg: msg) -> Effect(msg) {
  effect.from(fn(dispatch) { schedule(delay_ms, fn() { dispatch(msg) }) })
}

@external(javascript, "./scheduler_ffi.mjs", "schedule")
fn schedule(delay_ms: Int, callback: fn() -> Nil) -> Nil
