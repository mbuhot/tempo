//// The leave read models and their JSON codecs: the board's as-of `LeaveBalance`
//// readout and the engineer-detail `LeaveRecord` history row. Pure Gleam, no
//// target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire

/// An engineer's leave balances (days accrued − taken) for a date — the board
/// readout. Computed as-of, so it recomputes as the slider moves.
pub type LeaveBalance {
  LeaveBalance(engineer: String, annual: Float, sick: Float)
}

/// One row of an engineer's leave history: a leave `kind` over the leave window
/// `[valid_from, valid_to)`.
pub type LeaveRecord {
  LeaveRecord(kind: String, valid_from: Date, valid_to: Date)
}

/// Encode a `LeaveBalance` as a JSON object.
pub fn encode_leave_balance(balance: LeaveBalance) -> Json {
  let LeaveBalance(engineer:, annual:, sick:) = balance
  json.object([
    #("engineer", json.string(engineer)),
    #("annual", json.float(annual)),
    #("sick", json.float(sick)),
  ])
}

/// Decode a `LeaveBalance` from a JSON object.
pub fn leave_balance_decoder() -> Decoder(LeaveBalance) {
  use engineer <- decode.field("engineer", decode.string)
  use annual <- decode.field("annual", decode.float)
  use sick <- decode.field("sick", decode.float)
  decode.success(LeaveBalance(engineer:, annual:, sick:))
}

/// Encode a `LeaveRecord` (one leave-history row) as a JSON object.
pub fn encode_leave_record(record: LeaveRecord) -> Json {
  let LeaveRecord(kind:, valid_from:, valid_to:) = record
  json.object([
    #("kind", json.string(kind)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_date(valid_to)),
  ])
}

/// Decode a `LeaveRecord` from a JSON object.
pub fn leave_record_decoder() -> Decoder(LeaveRecord) {
  use kind <- decode.field("kind", decode.string)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.date_decoder())
  decode.success(LeaveRecord(kind:, valid_from:, valid_to:))
}
