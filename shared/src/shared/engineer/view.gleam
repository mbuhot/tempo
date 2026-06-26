//// The engineer read models and their JSON codecs: the edit-grouped contact/
//// banking/emergency facts, the as-of `Employment`, the `RoleVersion` history
//// row, and the `EngineerDetail` bundle. Pure Gleam, no target-specific deps, so
//// they round-trip on both ends of the JSON-over-HTTP boundary. Dates serialise
//// as ISO-8601 "YYYY-MM-DD" strings; money fields decode leniently.
//// `EngineerDetail` embeds the allocation rows from `shared/allocation/view` and
//// the leave balance + history from `shared/leave/view`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/allocation/view as allocation_view
import shared/leave/view as leave_view
import shared/money.{type Money}
import shared/wire

/// An engineer's contact details as one edit-grouped fact: the person's
/// `name`, `email`, `phone`, and `postal_address`. The underlying
/// `engineer_contact` table is period-keyed (`recorded_during`) and
/// append-only, read LATEST — so this record carries only the scalar fields of
/// the most-recently-recorded version, not its transaction-time bounds.
pub type EngineerContact {
  EngineerContact(
    engineer_id: Int,
    name: String,
    email: String,
    phone: String,
    postal_address: String,
  )
}

/// An engineer's banking details as one edit-grouped fact: `bank`, `branch`,
/// `account_no` (text, never numeric — it may carry leading zeros), and
/// `account_name`. Backed by the append-only `engineer_banking` table read
/// LATEST; this record is the most-recently-recorded version's scalar fields.
pub type EngineerBanking {
  EngineerBanking(
    engineer_id: Int,
    bank: String,
    branch: String,
    account_no: String,
    account_name: String,
  )
}

/// An engineer's emergency contact as one edit-grouped fact: the `relation`
/// (e.g. "spouse"), the contact's `name`, `phone`, and `email`. Backed by the
/// append-only `engineer_emergency` table read LATEST; this record is the
/// most-recently-recorded version's scalar fields.
pub type EngineerEmergency {
  EngineerEmergency(
    engineer_id: Int,
    relation: String,
    name: String,
    phone: String,
    email: String,
  )
}

/// An engineer's employment fact as-of a date: when they `started`, their `level`,
/// and their `monthly_salary` (a cost figure). Assembled from the range-only
/// employment row joined to `engineer_role` (level) and `salary` (monthly_salary)
/// as-of. Band is derived client-side from `level`.
pub type Employment {
  Employment(engineer_id: Int, started: Date, level: Int, monthly_salary: Money)
}

/// One version of an engineer's role history (a `engineer_role` period decomposed
/// to plain dates): the `level` held over `[valid_from, valid_to)`. Band is
/// derived client-side from `level`.
pub type RoleVersion {
  RoleVersion(level: Int, valid_from: Date, valid_to: Date)
}

/// The engineer-detail read model (`GET /api/engineers/:id?as_of=`): the engineer's
/// `name`/`level`, their current contact/banking/emergency facts, the as-of
/// `employment`, their full `roles`/`allocations`/`leave_history`, and their
/// leave `balance` (annual + sick). The timesheet is a separate fetch. Band is
/// derived client-side from `level`.
pub type EngineerDetail {
  EngineerDetail(
    engineer_id: Int,
    name: String,
    level: Int,
    contact: EngineerContact,
    banking: EngineerBanking,
    emergency: EngineerEmergency,
    employment: Employment,
    roles: List(RoleVersion),
    allocations: List(allocation_view.AllocationRow),
    balance: leave_view.LeaveBalance,
    leave_history: List(leave_view.LeaveRecord),
  )
}

/// Encode an `EngineerContact` (the engineer's current contact fact) as a JSON
/// object.
pub fn encode_engineer_contact(contact: EngineerContact) -> Json {
  let EngineerContact(engineer_id:, name:, email:, phone:, postal_address:) =
    contact
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("phone", json.string(phone)),
    #("postal_address", json.string(postal_address)),
  ])
}

/// Decode an `EngineerContact` from a JSON object.
pub fn engineer_contact_decoder() -> Decoder(EngineerContact) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use phone <- decode.field("phone", decode.string)
  use postal_address <- decode.field("postal_address", decode.string)
  decode.success(EngineerContact(
    engineer_id:,
    name:,
    email:,
    phone:,
    postal_address:,
  ))
}

/// Encode an `EngineerBanking` (the engineer's current banking fact) as a JSON
/// object.
pub fn encode_engineer_banking(banking: EngineerBanking) -> Json {
  let EngineerBanking(engineer_id:, bank:, branch:, account_no:, account_name:) =
    banking
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("bank", json.string(bank)),
    #("branch", json.string(branch)),
    #("account_no", json.string(account_no)),
    #("account_name", json.string(account_name)),
  ])
}

/// Decode an `EngineerBanking` from a JSON object.
pub fn engineer_banking_decoder() -> Decoder(EngineerBanking) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use bank <- decode.field("bank", decode.string)
  use branch <- decode.field("branch", decode.string)
  use account_no <- decode.field("account_no", decode.string)
  use account_name <- decode.field("account_name", decode.string)
  decode.success(EngineerBanking(
    engineer_id:,
    bank:,
    branch:,
    account_no:,
    account_name:,
  ))
}

/// Encode an `EngineerEmergency` (the engineer's current emergency contact) as
/// a JSON object.
pub fn encode_engineer_emergency(emergency: EngineerEmergency) -> Json {
  let EngineerEmergency(engineer_id:, relation:, name:, phone:, email:) =
    emergency
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("relation", json.string(relation)),
    #("name", json.string(name)),
    #("phone", json.string(phone)),
    #("email", json.string(email)),
  ])
}

/// Decode an `EngineerEmergency` from a JSON object.
pub fn engineer_emergency_decoder() -> Decoder(EngineerEmergency) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use relation <- decode.field("relation", decode.string)
  use name <- decode.field("name", decode.string)
  use phone <- decode.field("phone", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(EngineerEmergency(
    engineer_id:,
    relation:,
    name:,
    phone:,
    email:,
  ))
}

/// Encode an `Employment` (an engineer's as-of employment fact) as a JSON object.
pub fn encode_employment(employment: Employment) -> Json {
  let Employment(engineer_id:, started:, level:, monthly_salary:) = employment
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("started", wire.encode_date(started)),
    #("level", json.int(level)),
    #("monthly_salary", money.encode(monthly_salary)),
  ])
}

/// Decode an `Employment` from a JSON object.
pub fn employment_decoder() -> Decoder(Employment) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use started <- decode.field("started", wire.date_decoder())
  use level <- decode.field("level", decode.int)
  use monthly_salary <- decode.field("monthly_salary", money.decoder())
  decode.success(Employment(engineer_id:, started:, level:, monthly_salary:))
}

/// Encode a `RoleVersion` (one role-history version) as a JSON object.
pub fn encode_role_version(role: RoleVersion) -> Json {
  let RoleVersion(level:, valid_from:, valid_to:) = role
  json.object([
    #("level", json.int(level)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
  ])
}

/// Decode a `RoleVersion` from a JSON object.
pub fn role_version_decoder() -> Decoder(RoleVersion) {
  use level <- decode.field("level", decode.int)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  decode.success(RoleVersion(level:, valid_from:, valid_to:))
}

/// Encode an `EngineerDetail` (the engineer-detail read model) to JSON.
pub fn encode_engineer_detail(detail: EngineerDetail) -> Json {
  let EngineerDetail(
    engineer_id:,
    name:,
    level:,
    contact:,
    banking:,
    emergency:,
    employment:,
    roles:,
    allocations:,
    balance:,
    leave_history:,
  ) = detail
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("level", json.int(level)),
    #("contact", encode_engineer_contact(contact)),
    #("banking", encode_engineer_banking(banking)),
    #("emergency", encode_engineer_emergency(emergency)),
    #("employment", encode_employment(employment)),
    #("roles", json.array(roles, encode_role_version)),
    #(
      "allocations",
      json.array(allocations, allocation_view.encode_allocation_row),
    ),
    #("balance", leave_view.encode_leave_balance(balance)),
    #(
      "leave_history",
      json.array(leave_history, leave_view.encode_leave_record),
    ),
  ])
}

/// Decode an `EngineerDetail` from JSON.
pub fn engineer_detail_decoder() -> Decoder(EngineerDetail) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use level <- decode.field("level", decode.int)
  use contact <- decode.field("contact", engineer_contact_decoder())
  use banking <- decode.field("banking", engineer_banking_decoder())
  use emergency <- decode.field("emergency", engineer_emergency_decoder())
  use employment <- decode.field("employment", employment_decoder())
  use roles <- decode.field("roles", decode.list(role_version_decoder()))
  use allocations <- decode.field(
    "allocations",
    decode.list(allocation_view.allocation_row_decoder()),
  )
  use balance <- decode.field("balance", leave_view.leave_balance_decoder())
  use leave_history <- decode.field(
    "leave_history",
    decode.list(leave_view.leave_record_decoder()),
  )
  decode.success(EngineerDetail(
    engineer_id:,
    name:,
    level:,
    contact:,
    banking:,
    emergency:,
    employment:,
    roles:,
    allocations:,
    balance:,
    leave_history:,
  ))
}
