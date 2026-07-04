//// The read model for an engineer's location: a `LocationRecord` (a single dated span)
//// and `EngineerLocation` (an engineer plus their location as-of a date, or none).

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

pub type LocationRecord {
  LocationRecord(
    country: String,
    region: Option(String),
    timezone: String,
    valid_from: Date,
    valid_to: Option(Date),
    utc_offset_minutes: Int,
  )
}

pub type EngineerLocation {
  EngineerLocation(
    engineer_id: Int,
    name: String,
    location: Option(LocationRecord),
  )
}

pub fn encode_location_record(record: LocationRecord) -> Json {
  let LocationRecord(
    country:,
    region:,
    timezone:,
    valid_from:,
    valid_to:,
    utc_offset_minutes:,
  ) = record
  json.object([
    #("country", json.string(country)),
    #("region", json.nullable(region, json.string)),
    #("timezone", json.string(timezone)),
    #("valid_from", wire.encode_date(valid_from)),
    #("valid_to", wire.encode_option_date(valid_to)),
    #("utc_offset_minutes", json.int(utc_offset_minutes)),
  ])
}

pub fn location_record_decoder() -> Decoder(LocationRecord) {
  use country <- decode.field("country", decode.string)
  use region <- decode.field("region", decode.optional(decode.string))
  use timezone <- decode.field("timezone", decode.string)
  use valid_from <- decode.field("valid_from", wire.date_decoder())
  use valid_to <- decode.field("valid_to", wire.option_date_decoder())
  use utc_offset_minutes <- decode.field("utc_offset_minutes", decode.int)
  decode.success(LocationRecord(
    country:,
    region:,
    timezone:,
    valid_from:,
    valid_to:,
    utc_offset_minutes:,
  ))
}

pub fn encode_engineer_location(entry: EngineerLocation) -> Json {
  let EngineerLocation(engineer_id:, name:, location:) = entry
  json.object([
    #("engineer_id", json.int(engineer_id)),
    #("name", json.string(name)),
    #("location", json.nullable(location, encode_location_record)),
  ])
}

pub fn engineer_location_decoder() -> Decoder(EngineerLocation) {
  use engineer_id <- decode.field("engineer_id", decode.int)
  use name <- decode.field("name", decode.string)
  use location <- decode.field(
    "location",
    decode.optional(location_record_decoder()),
  )
  decode.success(EngineerLocation(engineer_id:, name:, location:))
}
