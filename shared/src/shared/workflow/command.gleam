//// Workflow write commands. Phase 1 carries one: committing a completed onboarding
//// draft, which the server interprets into the engineer facts. Draft mutations
//// (save field, complete step, hand off) are NOT commands — they go through the
//// un-journaled `/api/workflows` API — so only the commit is journaled.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type WorkflowCommand {
  CommitOnboarding(instance_id: String)
}

pub fn encode(command: WorkflowCommand) -> Json {
  case command {
    CommitOnboarding(instance_id:) ->
      json.object([
        #("op", json.string("commit_onboarding")),
        #("instance_id", json.string(instance_id)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(WorkflowCommand), Nil) {
  case op {
    "commit_onboarding" ->
      Ok({
        use instance_id <- decode.field("instance_id", decode.string)
        decode.success(CommitOnboarding(instance_id:))
      })
    _ -> Error(Nil)
  }
}
