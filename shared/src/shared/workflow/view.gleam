//// The read models the client renders: `DraftView` is one in-flight workflow
//// instance — its lifecycle status, the open step, every saved field value, and a
//// per-step completion status. `DraftSummary` is one row of the resume list.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import shared/workflow/value.{type FieldValue}

/// Where a step sits relative to the open one: already completed, the current
/// screen, still ahead, or gated until earlier steps are done.
pub type StepStatus {
  Pending
  Active
  Done
  Locked
}

/// One in-flight instance. `values` is keyed `"step.field"`; `step_status` is keyed
/// by step id. `assignee_is_me` tells the client whether the signed-in user is the
/// one this instance currently awaits (drives the commit/confirm affordance).
pub type DraftView {
  DraftView(
    instance_id: String,
    kind: String,
    status: String,
    current_step: String,
    assignee_is_me: Bool,
    values: Dict(String, FieldValue),
    step_status: Dict(String, StepStatus),
  )
}

/// One row of the resume list: enough to label the draft and route to it.
pub type DraftSummary {
  DraftSummary(
    instance_id: String,
    kind: String,
    status: String,
    title: String,
    current_step: String,
    awaiting_me: Bool,
  )
}

pub fn step_status_to_string(status: StepStatus) -> String {
  case status {
    Pending -> "pending"
    Active -> "active"
    Done -> "done"
    Locked -> "locked"
  }
}

fn step_status_from_string(text: String) -> StepStatus {
  case text {
    "active" -> Active
    "done" -> Done
    "locked" -> Locked
    _ -> Pending
  }
}

pub fn encode_draft(draft: DraftView) -> Json {
  json.object([
    #("instance_id", json.string(draft.instance_id)),
    #("kind", json.string(draft.kind)),
    #("status", json.string(draft.status)),
    #("current_step", json.string(draft.current_step)),
    #("assignee_is_me", json.bool(draft.assignee_is_me)),
    #("values", encode_values(draft.values)),
    #("step_status", encode_step_status(draft.step_status)),
  ])
}

fn encode_values(values: Dict(String, FieldValue)) -> Json {
  values
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, value.encode(pair.1)) })
  |> json.object
}

fn encode_step_status(statuses: Dict(String, StepStatus)) -> Json {
  statuses
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(step_status_to_string(pair.1))) })
  |> json.object
}

pub fn draft_decoder() -> Decoder(DraftView) {
  use instance_id <- decode.field("instance_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use status <- decode.field("status", decode.string)
  use current_step <- decode.field("current_step", decode.string)
  use assignee_is_me <- decode.field("assignee_is_me", decode.bool)
  use values <- decode.field(
    "values",
    decode.dict(decode.string, value.decoder()),
  )
  use step_status <- decode.field(
    "step_status",
    decode.dict(
      decode.string,
      decode.map(decode.string, step_status_from_string),
    ),
  )
  decode.success(DraftView(
    instance_id:,
    kind:,
    status:,
    current_step:,
    assignee_is_me:,
    values:,
    step_status:,
  ))
}

pub fn encode_summary(summary: DraftSummary) -> Json {
  json.object([
    #("instance_id", json.string(summary.instance_id)),
    #("kind", json.string(summary.kind)),
    #("status", json.string(summary.status)),
    #("title", json.string(summary.title)),
    #("current_step", json.string(summary.current_step)),
    #("awaiting_me", json.bool(summary.awaiting_me)),
  ])
}

pub fn summary_decoder() -> Decoder(DraftSummary) {
  use instance_id <- decode.field("instance_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use status <- decode.field("status", decode.string)
  use title <- decode.field("title", decode.string)
  use current_step <- decode.field("current_step", decode.string)
  use awaiting_me <- decode.field("awaiting_me", decode.bool)
  decode.success(DraftSummary(
    instance_id:,
    kind:,
    status:,
    title:,
    current_step:,
    awaiting_me:,
  ))
}

pub fn encode_summaries(summaries: List(DraftSummary)) -> Json {
  json.array(summaries, encode_summary)
}

pub fn summaries_decoder() -> Decoder(List(DraftSummary)) {
  decode.list(summary_decoder())
}
