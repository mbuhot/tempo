//// The write command for engineer location: `SetEngineerLocation` sets a location from an
//// effective date onward. Tagged by `op` on the wire, like every aggregate command.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import shared/wire.{date_decoder, encode_date}

pub type LocationCommand {
  SetEngineerLocation(
    engineer_id: Int,
    country: String,
    region: Option(String),
    timezone: String,
    effective: Date,
  )
}

pub fn encode(command: LocationCommand) -> Json {
  case command {
    SetEngineerLocation(engineer_id:, country:, region:, timezone:, effective:) ->
      json.object([
        #("op", json.string("set_engineer_location")),
        #("engineer_id", json.int(engineer_id)),
        #("country", json.string(country)),
        #("region", json.nullable(region, json.string)),
        #("timezone", json.string(timezone)),
        #("effective", encode_date(effective)),
      ])
  }
}

pub fn decoder(op: String) -> Result(Decoder(LocationCommand), Nil) {
  case op {
    "set_engineer_location" ->
      Ok({
        use engineer_id <- decode.field("engineer_id", decode.int)
        use country <- decode.field("country", decode.string)
        use region <- decode.field("region", decode.optional(decode.string))
        use timezone <- decode.field("timezone", decode.string)
        use effective <- decode.field("effective", date_decoder())
        decode.success(SetEngineerLocation(
          engineer_id:,
          country:,
          region:,
          timezone:,
          effective:,
        ))
      })
    _ -> Error(Nil)
  }
}
