//// The client aggregate's write command type and its JSON codec (the single
//// edit-grouped profile fact: the client's name). `encode` tags the variant by its
//// `op`; `decoder` returns the field decoder for an `op` this aggregate owns
//// (`Error(Nil)` for any other), so `shared/command.command_decoder` can dispatch
//// by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type ClientCommand {
  /// Record a new profile for a client effective from a date: close the
  /// `client_profile` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `name` (a temporal Change on the append-only
  /// client_profile fact). A client has only a name, so this is its single
  /// Update command.
  UpdateClientProfile(client_id: Int, name: String, effective: Date)
}

/// Encode a `ClientCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: ClientCommand) -> Json {
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

/// The field decoder for a client `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(ClientCommand), Nil) {
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
