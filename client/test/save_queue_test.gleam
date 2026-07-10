import client/workflow/save_queue
import gleam/option

pub fn a_save_while_idle_dispatches_immediately_test() {
  let #(pending, dispatch) =
    save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  assert dispatch == option.Some(#("identity", "doc-a"))
  assert pending == save_queue.Saving(queued: [], advance: option.None)
}

pub fn a_save_during_an_in_flight_save_queues_and_dispatches_on_completion_test() {
  let #(pending, _) = save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  let #(pending, dispatch) = save_queue.enqueue(pending, "bank", "doc-b")
  assert dispatch == option.None
  assert pending
    == save_queue.Saving(queued: [#("bank", "doc-b")], advance: option.None)

  let #(pending, next) = save_queue.completed(pending)
  assert next == save_queue.DispatchSave(step: "bank", doc: "doc-b")
  assert pending == save_queue.Saving(queued: [], advance: option.None)
}

pub fn rapid_saves_to_the_same_step_coalesce_to_the_latest_document_test() {
  let #(pending, _) = save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  let #(pending, first_dispatch) =
    save_queue.enqueue(pending, "identity", "doc-b")
  let #(pending, second_dispatch) =
    save_queue.enqueue(pending, "identity", "doc-c")
  assert first_dispatch == option.None
  assert second_dispatch == option.None
  assert pending
    == save_queue.Saving(queued: [#("identity", "doc-c")], advance: option.None)
}

pub fn saves_to_different_steps_dispatch_in_original_order_after_the_in_flight_save_completes_test() {
  let #(pending, _) = save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  let #(pending, _) = save_queue.enqueue(pending, "bank", "doc-b")
  let #(pending, _) = save_queue.enqueue(pending, "contact", "doc-c")

  let #(pending, first_next) = save_queue.completed(pending)
  assert first_next == save_queue.DispatchSave(step: "bank", doc: "doc-b")

  let #(pending, second_next) = save_queue.completed(pending)
  assert second_next == save_queue.DispatchSave(step: "contact", doc: "doc-c")

  let #(_pending, third_next) = save_queue.completed(pending)
  assert third_next == save_queue.Settled
}

pub fn an_advance_requested_mid_save_fires_only_after_the_queue_drains_test() {
  let #(pending, _) = save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  let #(pending, _) = save_queue.enqueue(pending, "bank", "doc-b")
  let #(pending, dispatch_now) =
    save_queue.request_advance(pending, save_queue.HandOff)
  assert dispatch_now == False

  let #(pending, first_next) = save_queue.completed(pending)
  assert first_next == save_queue.DispatchSave(step: "bank", doc: "doc-b")

  let #(_pending, second_next) = save_queue.completed(pending)
  assert second_next == save_queue.FireAdvance(save_queue.HandOff)
}

pub fn an_advance_requested_while_idle_dispatches_immediately_test() {
  let #(pending, dispatch_now) =
    save_queue.request_advance(save_queue.Idle, save_queue.Commit)
  assert dispatch_now == True
  assert pending == save_queue.Idle
}

pub fn a_failed_save_cancels_queued_saves_and_the_pending_advance_test() {
  let #(pending, _) = save_queue.enqueue(save_queue.Idle, "identity", "doc-a")
  let #(pending, _) = save_queue.enqueue(pending, "bank", "doc-b")
  let #(pending, _) = save_queue.request_advance(pending, save_queue.Commit)

  let pending = save_queue.failed(pending)
  assert pending == save_queue.Idle
}
