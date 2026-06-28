//// The client seam for the workflow draft API (`/api/workflows`) and the journaled
//// commit. Draft reads/writes are plain JSON calls; the commit goes through the
//// shared operations envelope so the server journals it. Pages call these and never
//// build URLs or bodies themselves.

import client/api
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import lustre/effect.{type Effect}
import rsvp
import shared/command.{WorkflowCommand}
import shared/workflow/command.{CommitOnboarding}
import shared/workflow/schema.{type WorkflowSchema}
import shared/workflow/value.{type FieldValue}
import shared/workflow/view.{type DraftSummary, type DraftView}

/// GET the schema for a workflow kind.
pub fn fetch_schema(
  kind: String,
  to_msg: fn(Result(WorkflowSchema, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  api.get("/api/workflows/schema/" <> kind, schema.schema_decoder(), to_msg)
}

/// GET the caller's resumable drafts.
pub fn fetch_drafts(
  to_msg: fn(Result(List(DraftSummary), rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  api.get("/api/workflows", view.summaries_decoder(), to_msg)
}

/// GET one draft view.
pub fn fetch_draft(
  id: String,
  to_msg: fn(Result(DraftView, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  api.get("/api/workflows/" <> id, view.draft_decoder(), to_msg)
}

/// POST a new draft of `kind`; the result is the new instance id.
pub fn start(
  kind: String,
  to_msg: fn(Result(String, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/workflows",
    json.object([#("kind", json.string(kind))]),
    rsvp.expect_json(instance_id_decoder(), to_msg),
  )
}

/// POST one field value to a draft.
pub fn save_field(
  id: String,
  step: String,
  field: String,
  field_value: FieldValue,
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/workflows/" <> id <> "/field",
    json.object([
      #("step", json.string(step)),
      #("field", json.string(field)),
      #("value", value.encode(field_value)),
    ]),
    rsvp.expect_json(decode.success(Nil), to_msg),
  )
}

/// POST to advance the draft's open step.
pub fn complete_step(
  id: String,
  next_step: String,
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/workflows/" <> id <> "/step",
    json.object([#("next_step", json.string(next_step))]),
    rsvp.expect_json(decode.success(Nil), to_msg),
  )
}

/// POST to hand the draft to a Finance assignee.
pub fn hand_off(
  id: String,
  assignee_id: Int,
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/workflows/" <> id <> "/handoff",
    json.object([#("assignee_id", json.int(assignee_id))]),
    rsvp.expect_json(decode.success(Nil), to_msg),
  )
}

/// POST to cancel the draft.
pub fn cancel(
  id: String,
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  rsvp.post(
    "/api/workflows/" <> id <> "/cancel",
    json.object([]),
    rsvp.expect_json(decode.success(Nil), to_msg),
  )
}

/// Commit a completed onboarding draft — a journaled command via /api/operations.
pub fn commit(
  id: String,
  to_msg: fn(Result(Nil, rsvp.Error(String))) -> msg,
) -> Effect(msg) {
  api.submit_operation(WorkflowCommand(CommitOnboarding(id)), to_msg)
}

fn instance_id_decoder() -> Decoder(String) {
  use instance_id <- decode.field("instance_id", decode.string)
  decode.success(instance_id)
}
