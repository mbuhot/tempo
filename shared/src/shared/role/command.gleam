//// The role aggregate's write command type and its JSON codec — the access-control
//// slice of the command wire contract. `GrantUserRole`/`RevokeUserRole` assign or
//// revoke a user's role effective from a date (the temporal `user_role` map); only a
//// principal with `roles.manage` may run them. `encode` tags each variant by its `op`;
//// `decoder` returns the field decoder for an `op` this aggregate owns.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type RoleCommand {
  /// Grant `role` to the account from `effective`, opening an open-ended held period.
  GrantUserRole(account_id: Int, role: String, effective: Date)
  /// Revoke `role` from the account from `effective`, capping its held period there.
  RevokeUserRole(account_id: Int, role: String, effective: Date)
}

/// Encode a `RoleCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: RoleCommand) -> Json {
  case command {
    GrantUserRole(account_id:, role:, effective:) ->
      json.object([
        #("op", json.string("grant_user_role")),
        #("account_id", json.int(account_id)),
        #("role", json.string(role)),
        #("effective", encode_date(effective)),
      ])
    RevokeUserRole(account_id:, role:, effective:) ->
      json.object([
        #("op", json.string("revoke_user_role")),
        #("account_id", json.int(account_id)),
        #("role", json.string(role)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for a role `op`, or `Error(Nil)` for an op this aggregate does not
/// own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(RoleCommand), Nil) {
  case op {
    "grant_user_role" ->
      Ok({
        use account_id <- decode.field("account_id", decode.int)
        use role <- decode.field("role", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(GrantUserRole(account_id:, role:, effective:))
      })
    "revoke_user_role" ->
      Ok({
        use account_id <- decode.field("account_id", decode.int)
        use role <- decode.field("role", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(RevokeUserRole(account_id:, role:, effective:))
      })
    _ -> Error(Nil)
  }
}
