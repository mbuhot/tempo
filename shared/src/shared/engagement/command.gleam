//// The engagement aggregate's write command type and its JSON codec (contracts and
//// the projects contained by them). `encode` tags each variant by its `op`;
//// `decoder` returns the field decoder for an `op` the engagement aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type EngagementCommand {
  /// Open a contract term for a client.
  SignContract(client: String, valid_from: Date, valid_to: Date)
  /// Start a project under a contract for a bounded active period.
  StartProject(name: String, contract_id: Int, valid_from: Date, valid_to: Date)
  /// Move a project's whole plan to a new [from, to) run window.
  RescheduleProject(project_id: Int, valid_from: Date, valid_to: Date)
}

/// Encode an `EngagementCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: EngagementCommand) -> Json {
  case command {
    SignContract(client:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("sign_contract")),
        #("client", json.string(client)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    StartProject(name:, contract_id:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("start_project")),
        #("name", json.string(name)),
        #("contract_id", json.int(contract_id)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
    RescheduleProject(project_id:, valid_from:, valid_to:) ->
      json.object([
        #("op", json.string("reschedule_project")),
        #("project_id", json.int(project_id)),
        #("valid_from", encode_date(valid_from)),
        #("valid_to", encode_date(valid_to)),
      ])
  }
}

/// The field decoder for an engagement `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(EngagementCommand), Nil) {
  case op {
    "sign_contract" ->
      Ok({
        use client <- decode.field("client", decode.string)
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(SignContract(client:, valid_from:, valid_to:))
      })
    "start_project" ->
      Ok({
        use name <- decode.field("name", decode.string)
        use contract_id <- decode.field("contract_id", decode.int)
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(StartProject(name:, contract_id:, valid_from:, valid_to:))
      })
    "reschedule_project" ->
      Ok({
        use project_id <- decode.field("project_id", decode.int)
        use valid_from <- decode.field("valid_from", date_decoder())
        use valid_to <- decode.field("valid_to", date_decoder())
        decode.success(RescheduleProject(project_id:, valid_from:, valid_to:))
      })
    _ -> Error(Nil)
  }
}
