//// Serializes step-document saves behind a single in-flight request so a stale
//// document can never overwrite a newer one.

import gleam/option.{type Option, None, Some}

/// At most one save in flight at a time; later saves queue and coalesce by step.
pub type Pending(doc) {
  Idle
  Saving(queued: List(#(String, doc)), advance: Option(Advance))
}

/// The step-ending action deferred until the queue drains.
pub type Advance {
  HandOff
  Commit
}

/// What to do once a save has landed.
pub type Next(doc) {
  DispatchSave(step: String, doc: doc)
  FireAdvance(Advance)
  Settled
}

/// Dispatch a step's save immediately when idle; otherwise queue it, replacing any
/// pending save for the same step with this newer document.
pub fn enqueue(
  pending: Pending(doc),
  step: String,
  doc: doc,
) -> #(Pending(doc), Option(#(String, doc))) {
  case pending {
    Idle -> #(Saving(queued: [], advance: None), Some(#(step, doc)))
    Saving(queued:, advance:) -> #(
      Saving(queued: coalesce(queued, step, doc), advance:),
      None,
    )
  }
}

fn coalesce(
  queued: List(#(String, doc)),
  step: String,
  doc: doc,
) -> List(#(String, doc)) {
  case queued {
    [] -> [#(step, doc)]
    [#(queued_step, _), ..rest] if queued_step == step -> [#(step, doc), ..rest]
    [head, ..rest] -> [head, ..coalesce(rest, step, doc)]
  }
}

/// Advance the queue once the in-flight save lands: dispatch the next queued save,
/// fire a pending advance, or settle.
pub fn completed(pending: Pending(doc)) -> #(Pending(doc), Next(doc)) {
  case pending {
    Saving(queued: [#(step, doc), ..rest], advance:) -> #(
      Saving(queued: rest, advance:),
      DispatchSave(step:, doc:),
    )
    Saving(queued: [], advance: Some(advance)) -> #(Idle, FireAdvance(advance))
    Saving(queued: [], advance: None) -> #(Idle, Settled)
    Idle -> #(Idle, Settled)
  }
}

/// Cancel any queued saves and pending advance after a save comes back an error.
pub fn failed(_pending: Pending(doc)) -> Pending(doc) {
  Idle
}

/// Dispatch a hand-off or commit immediately when idle; otherwise hold it until the
/// queue drains.
pub fn request_advance(
  pending: Pending(doc),
  advance: Advance,
) -> #(Pending(doc), Bool) {
  case pending {
    Idle -> #(Idle, True)
    Saving(queued:, ..) -> #(Saving(queued:, advance: Some(advance)), False)
  }
}
