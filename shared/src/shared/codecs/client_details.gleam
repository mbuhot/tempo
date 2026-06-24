//// JSON codec for `ClientDetailsCommand` — the client-details aggregate's slice of
//// the command wire contract (the single edit-grouped profile fact: the client's
//// name). `encode` tags the variant by its `op`; `decoder` returns the field
//// decoder for an `op` this aggregate owns (`Error(Nil)` for any other), so the
//// top-level `codecs.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date}
import shared/types.{type ClientDetailsCommand, UpdateClientProfile}

/// Encode a `ClientDetailsCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: ClientDetailsCommand) -> Json {
  case command {
    UpdateClientProfile(client_id:, name:, effective:) ->
      json.object([
        #("op", json.string("update_client_profile")),
        #("client_id", json.int(client_id)),
        #("name", json.string(name)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a client-details `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(ClientDetailsCommand), Nil) {
  case op {
    "update_client_profile" ->
      Ok({
        use client_id <- decode.field("client_id", decode.int)
        use name <- decode.field("name", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateClientProfile(client_id:, name:, effective:))
      })
    _ -> Error(Nil)
  }
}
