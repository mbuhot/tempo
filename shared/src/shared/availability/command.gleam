//// Write commands for availability inputs: weekly working hours, focus blocks, and
//// public-holiday import. Each is tagged by `op` for the grouped command decoder.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type DayHours {
  DayHours(weekday: Int, hours: Option(#(String, String)))
}

pub type HolidayRow {
  HolidayRow(country: String, region: String, holiday_on: Date, name: String)
}

pub type AvailabilityCommand {
  SetWorkSchedule(engineer_id: Int, effective: Date, days: List(DayHours))
  AddFocusBlock(
    engineer_id: Int,
    date: Date,
    starts_at: String,
    duration_minutes: Int,
    timezone: String,
    title: String,
  )
  RemoveFocusBlock(engineer_id: Int, focus_block_id: Int)
  ImportHolidays(rows: List(HolidayRow))
}

fn encode_day(day: DayHours) -> Json {
  let #(starts, ends) = case day.hours {
    Some(#(starts, ends)) -> #(Some(starts), Some(ends))
    None -> #(None, None)
  }
  json.object([
    #("weekday", json.int(day.weekday)),
    #("starts", json.nullable(starts, json.string)),
    #("ends", json.nullable(ends, json.string)),
  ])
}

fn day_decoder() -> Decoder(DayHours) {
  use weekday <- decode.field("weekday", decode.int)
  use starts <- decode.field("starts", decode.optional(decode.string))
  use ends <- decode.field("ends", decode.optional(decode.string))
  let hours = case starts, ends {
    Some(starts_value), Some(ends_value) -> Some(#(starts_value, ends_value))
    _, _ -> None
  }
  decode.success(DayHours(weekday:, hours:))
}

fn encode_holiday_row(row: HolidayRow) -> Json {
  json.object([
    #("country", json.string(row.country)),
    #("region", json.string(row.region)),
    #("holiday_on", encode_date(row.holiday_on)),
    #("name", json.string(row.name)),
  ])
}

fn holiday_row_decoder() -> Decoder(HolidayRow) {
  use country <- decode.field("country", decode.string)
  use region <- decode.field("region", decode.string)
  use holiday_on <- decode.field("holiday_on", date_decoder())
  use name <- decode.field("name", decode.string)
  decode.success(HolidayRow(country:, region:, holiday_on:, name:))
}

pub fn encode(command: AvailabilityCommand) -> Json {
  case command {
    SetWorkSchedule(engineer_id:, effective:, days:) ->
      json.object([
        #("op", json.string("set_work_schedule")),
        #("engineer_id", json.int(engineer_id)),
        #("effective", encode_date(effective)),
        #("days", json.array(days, encode_day)),
      ])
    AddFocusBlock(
      engineer_id:,
      date:,
      starts_at:,
      duration_minutes:,
      timezone:,
      title:,
    ) ->
      json.object([
        #("op", json.string("add_focus_block")),
        #("engineer_id", json.int(engineer_id)),
        #("date", encode_date(date)),
        #("starts_at", json.string(starts_at)),
        #("duration_minutes", json.int(duration_minutes)),
        #("timezone", json.string(timezone)),
        #("title", json.string(title)),
      ])
    RemoveFocusBlock(engineer_id:, focus_block_id:) ->
      json.object([
        #("op", json.string("remove_focus_block")),
        #("engineer_id", json.int(engineer_id)),
        #("focus_block_id", json.int(focus_block_id)),
      ])
    ImportHolidays(rows:) ->
      json.object([
        #("op", json.string("import_holidays")),
        #("rows", json.array(rows, encode_holiday_row)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(AvailabilityCommand), Nil) {
  case op {
    "set_work_schedule" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use effective <- decode.field("effective", date_decoder())
        use days <- decode.field("days", decode.list(day_decoder()))
        decode.success(SetWorkSchedule(engineer_id:, effective:, days:))
      })
    "add_focus_block" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use date <- decode.field("date", date_decoder())
        use starts_at <- decode.field("starts_at", decode.string)
        use duration_minutes <- decode.field("duration_minutes", decode.int)
        use timezone <- decode.field("timezone", decode.string)
        use title <- decode.field("title", decode.string)
        decode.success(AddFocusBlock(
          engineer_id:,
          date:,
          starts_at:,
          duration_minutes:,
          timezone:,
          title:,
        ))
      })
    "remove_focus_block" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use focus_block_id <- decode.field("focus_block_id", decode.int)
        decode.success(RemoveFocusBlock(engineer_id:, focus_block_id:))
      })
    "import_holidays" ->
      Ok({
        use rows <- decode.field("rows", decode.list(holiday_row_decoder()))
        decode.success(ImportHolidays(rows:))
      })
    _ -> Error(Nil)
  }
}
