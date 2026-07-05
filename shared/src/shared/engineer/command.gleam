//// The engineer aggregate's write command type and its JSON codec — the engineer
//// slice of the command wire contract (ARCHITECTURE.md: one handler, understood in
//// isolation). Covers the identity lifecycle (onboard/promote/terminate) and the
//// three edit-grouped facts that hang off the anchor (contact, banking,
//// emergency). `encode` tags each variant by its `op`; `decoder` returns the
//// field decoder for an `op` the engineer aggregate owns (`Error(Nil)` for any
//// other), so `shared/command.command_decoder` can dispatch by tag and wrap as
//// `Command`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type EngineerCommand {
  OnboardEngineer(name: String, level: Int, effective: Date)
  /// Promote an engineer to a new level effective from a date.
  Promote(engineer_id: Int, level: Int, effective: Date)
  /// Terminate an engineer's employment from a date, capping every contained fact.
  TerminateEmployment(engineer_id: Int, effective: Date)
  /// Record new contact details for an engineer effective from a date: close
  /// the `engineer_contact` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `name`/`email`/`phone`/`postal_address` (a
  /// temporal Change on the append-only contact fact).
  UpdateContactDetails(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
    effective: Date,
  )
  /// Record new banking details for an engineer effective from a date: close
  /// the `engineer_banking` row covering `effective` and open a new full row
  /// `[effective, NULL)` carrying `bank`/`branch`/`account_no`/`account_name`
  /// (a temporal Change on the append-only banking fact). `account_no` is text.
  UpdateBankingDetails(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
    effective: Date,
  )
  /// Record a new emergency contact for an engineer effective from a date:
  /// close the `engineer_emergency` row covering `effective` and open a new
  /// full row `[effective, NULL)` carrying `relation`/`name`/`phone`/`email`
  /// (a temporal Change on the append-only emergency fact).
  UpdateEmergencyContact(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
    effective: Date,
  )
}

/// Encode an `EngineerCommand` as a tagged JSON object keyed by `op`.
pub fn encode(command: EngineerCommand) -> Json {
  case command {
    OnboardEngineer(name:, level:, effective:) ->
      json.object([
        #("op", json.string("onboard_engineer")),
        #("name", json.string(name)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    Promote(engineer_id:, level:, effective:) ->
      json.object([
        #("op", json.string("promote")),
        #("engineer_id", json.int(engineer_id)),
        #("level", json.int(level)),
        #("effective", encode_date(effective)),
      ])
    TerminateEmployment(engineer_id:, effective:) ->
      json.object([
        #("op", json.string("terminate_employment")),
        #("engineer_id", json.int(engineer_id)),
        #("effective", encode_date(effective)),
      ])
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

/// The field decoder for an engineer `op`, or `Error(Nil)` for an op this aggregate
/// does not own (so the top-level dispatcher can try the next group).
pub fn decoder(op: String) -> Result(Decoder(EngineerCommand), Nil) {
  case op {
    "onboard_engineer" ->
      Ok({
        use name <- decode.field("name", decode.string)
        use level <- decode.field("level", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(OnboardEngineer(name:, level:, effective:))
      })
    "promote" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use level <- decode.field("level", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(Promote(engineer_id:, level:, effective:))
      })
    "terminate_employment" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        decode.success(TerminateEmployment(engineer_id:, effective:))
      })
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
