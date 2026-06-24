//// JSON codec for `EngineerDetailsCommand` — the engineer-details aggregate's slice
//// of the command wire contract (the three edit-grouped facts: contact, banking,
//// emergency). `encode` tags each variant by its `op`; `decoder` returns the field
//// decoder for an `op` this aggregate owns (`Error(Nil)` for any other), so the
//// top-level `codecs.command_decoder` can dispatch by tag and wrap as `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/codecs/base.{date_decoder, encode_date}
import shared/types.{
  type EngineerDetailsCommand, UpdateBankingDetails, UpdateContactDetails,
  UpdateEmergencyContact,
}

/// Encode an `EngineerDetailsCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: EngineerDetailsCommand) -> Json {
  case command {
    UpdateContactDetails(
      engineer_id:,
      name:,
      email:,
      phone:,
      postal_address:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_contact_details")),
        #("engineer_id", json.int(engineer_id)),
        #("name", json.string(name)),
        #("email", json.string(email)),
        #("phone", json.string(phone)),
        #("postal_address", json.string(postal_address)),
        #("effective", encode_date(effective)),
      ])
    UpdateBankingDetails(
      engineer_id:,
      bank:,
      branch:,
      account_no:,
      account_name:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_banking_details")),
        #("engineer_id", json.int(engineer_id)),
        #("bank", json.string(bank)),
        #("branch", json.string(branch)),
        #("account_no", json.string(account_no)),
        #("account_name", json.string(account_name)),
        #("effective", encode_date(effective)),
      ])
    UpdateEmergencyContact(
      engineer_id:,
      relation:,
      name:,
      phone:,
      email:,
      effective:,
    ) ->
      json.object([
        #("op", json.string("update_emergency_contact")),
        #("engineer_id", json.int(engineer_id)),
        #("relation", json.string(relation)),
        #("name", json.string(name)),
        #("phone", json.string(phone)),
        #("email", json.string(email)),
        #("effective", encode_date(effective)),
      ])
  }
}

/// The field decoder for an engineer-details `op`, or `Error(Nil)` for an op this
/// aggregate does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(EngineerDetailsCommand), Nil) {
  case op {
    "update_contact_details" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use name <- decode.field("name", decode.string)
        use email <- decode.field("email", decode.string)
        use phone <- decode.field("phone", decode.string)
        use postal_address <- decode.field("postal_address", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateContactDetails(
          engineer_id:,
          name:,
          email:,
          phone:,
          postal_address:,
          effective:,
        ))
      })
    "update_banking_details" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use bank <- decode.field("bank", decode.string)
        use branch <- decode.field("branch", decode.string)
        use account_no <- decode.field("account_no", decode.string)
        use account_name <- decode.field("account_name", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateBankingDetails(
          engineer_id:,
          bank:,
          branch:,
          account_no:,
          account_name:,
          effective:,
        ))
      })
    "update_emergency_contact" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use relation <- decode.field("relation", decode.string)
        use name <- decode.field("name", decode.string)
        use phone <- decode.field("phone", decode.string)
        use email <- decode.field("email", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(UpdateEmergencyContact(
          engineer_id:,
          relation:,
          name:,
          phone:,
          email:,
          effective:,
        ))
      })
    _ -> Error(Nil)
  }
}
