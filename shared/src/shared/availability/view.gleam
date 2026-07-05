//// The read model for one engineer's availability: their weekly working-hours
//// grid, upcoming focus blocks, and upcoming holidays for their location. Also
//// the standalone holidays listing across every seeded region. Instants cross
//// the wire as ISO-8601 UTC strings; times of day as `"HH:MM"` strings; dates
//// via `wire.encode_date`/`wire.date_decoder`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire

pub type DaySlot {
  DaySlot(weekday: Int, starts: Option(String), ends: Option(String))
}

pub type FocusBlockRecord {
  FocusBlockRecord(
    id: Int,
    title: String,
    starts_at: String,
    ends_at: String,
    offset_minutes: Option(Int),
  )
}

pub type EngineerHoliday {
  EngineerHoliday(holiday_on: Date, name: String)
}

pub type AvailabilityRecord {
  AvailabilityRecord(
    week: List(DaySlot),
    focus_blocks: List(FocusBlockRecord),
    holidays: List(EngineerHoliday),
  )
}

pub type HolidayListing {
  HolidayListing(
    country: String,
    region: String,
    region_name: String,
    holiday_on: Date,
    name: String,
  )
}

pub fn encode_day_slot(slot: DaySlot) -> Json {
  let DaySlot(weekday:, starts:, ends:) = slot
  json.object([
    #("weekday", json.int(weekday)),
    #("starts", json.nullable(starts, json.string)),
    #("ends", json.nullable(ends, json.string)),
  ])
}

pub fn day_slot_decoder() -> Decoder(DaySlot) {
  use weekday <- decode.field("weekday", decode.int)
  use starts <- decode.field("starts", decode.optional(decode.string))
  use ends <- decode.field("ends", decode.optional(decode.string))
  decode.success(DaySlot(weekday:, starts:, ends:))
}

pub fn encode_focus_block_record(record: FocusBlockRecord) -> Json {
  let FocusBlockRecord(id:, title:, starts_at:, ends_at:, offset_minutes:) =
    record
  json.object([
    #("id", json.int(id)),
    #("title", json.string(title)),
    #("starts_at", json.string(starts_at)),
    #("ends_at", json.string(ends_at)),
    #("offset_minutes", json.nullable(offset_minutes, json.int)),
  ])
}

pub fn focus_block_record_decoder() -> Decoder(FocusBlockRecord) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use starts_at <- decode.field("starts_at", decode.string)
  use ends_at <- decode.field("ends_at", decode.string)
  use offset_minutes <- decode.field(
    "offset_minutes",
    decode.optional(decode.int),
  )
  decode.success(FocusBlockRecord(
    id:,
    title:,
    starts_at:,
    ends_at:,
    offset_minutes:,
  ))
}

pub fn encode_engineer_holiday(holiday: EngineerHoliday) -> Json {
  let EngineerHoliday(holiday_on:, name:) = holiday
  json.object([
    #("holiday_on", wire.encode_date(holiday_on)),
    #("name", json.string(name)),
  ])
}

pub fn engineer_holiday_decoder() -> Decoder(EngineerHoliday) {
  use holiday_on <- decode.field("holiday_on", wire.date_decoder())
  use name <- decode.field("name", decode.string)
  decode.success(EngineerHoliday(holiday_on:, name:))
}

pub fn encode_availability_record(record: AvailabilityRecord) -> Json {
  let AvailabilityRecord(week:, focus_blocks:, holidays:) = record
  json.object([
    #("week", json.array(week, encode_day_slot)),
    #("focus_blocks", json.array(focus_blocks, encode_focus_block_record)),
    #("holidays", json.array(holidays, encode_engineer_holiday)),
  ])
}

pub fn availability_record_decoder() -> Decoder(AvailabilityRecord) {
  use week <- decode.field("week", decode.list(day_slot_decoder()))
  use focus_blocks <- decode.field(
    "focus_blocks",
    decode.list(focus_block_record_decoder()),
  )
  use holidays <- decode.field(
    "holidays",
    decode.list(engineer_holiday_decoder()),
  )
  decode.success(AvailabilityRecord(week:, focus_blocks:, holidays:))
}

pub fn encode_holiday_listing(listing: HolidayListing) -> Json {
  let HolidayListing(country:, region:, region_name:, holiday_on:, name:) =
    listing
  json.object([
    #("country", json.string(country)),
    #("region", json.string(region)),
    #("region_name", json.string(region_name)),
    #("holiday_on", wire.encode_date(holiday_on)),
    #("name", json.string(name)),
  ])
}

pub fn holiday_listing_decoder() -> Decoder(HolidayListing) {
  use country <- decode.field("country", decode.string)
  use region <- decode.field("region", decode.string)
  use region_name <- decode.field("region_name", decode.string)
  use holiday_on <- decode.field("holiday_on", wire.date_decoder())
  use name <- decode.field("name", decode.string)
  decode.success(HolidayListing(
    country:,
    region:,
    region_name:,
    holiday_on:,
    name:,
  ))
}
