//// The allocation read model and its JSON codec: one row of an engineer's
//// allocation history on the engineer-detail read model. Pure Gleam, no
//// target-specific deps, so it round-trips on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

/// One row of an engineer's allocation history: the project they were allocated to
/// at a `fraction` over `[valid_from, valid_to)`, with `active` true when the
/// period covers the detail's as-of date (the date marks rows active/ended, it
/// does not hide them).
pub type AllocationRow {
  AllocationRow(
    project_id: Int,
    project: String,
    fraction: Float,
    valid_from: Date,
    valid_to: Option(Date),
    active: Bool,
  )
}

/// Encode an `AllocationRow` (one allocation-history row) as a JSON object.
pub fn encode_allocation_row(allocation: AllocationRow) -> Json {
  let AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ) = allocation
  json.object([
    #("project_id", json.int(project_id)),
    #("project", json.string(project)),
    #("fraction", json.float(fraction)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_option_date(valid_to)),
    #("active", json.bool(active)),
  ])
}

/// Decode an `AllocationRow` from a JSON object.
pub fn allocation_row_decoder() -> Decoder(AllocationRow) {
  use project_id <- decode.field("project_id", decode.int)
  use project <- decode.field("project", decode.string)
  use fraction <- decode.field("fraction", wire.lenient_float_decoder())
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.option_date_decoder())
  use active <- decode.field("active", decode.bool)
  decode.success(AllocationRow(
    project_id:,
    project:,
    fraction:,
    valid_from:,
    valid_to:,
    active:,
  ))
}
