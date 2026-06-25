//// The forecast read models and their JSON codecs: one `ForecastMonth` of
//// projected revenue/cost/profit and the whole `Forecast` series. Pure Gleam, no
//// target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings; money/margin
//// fields decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/wire

/// One month of the forecast (`GET /api/forecast?as_of=`): the first-of-`month`
/// Date (the client formats it) and the projected `revenue`, `cost`, `profit`, and
/// `margin_pct` from committed demand for that month.
pub type ForecastMonth {
  ForecastMonth(
    month: Date,
    revenue: Float,
    cost: Float,
    profit: Float,
    margin_pct: Float,
  )
}

/// The forecast read model (`GET /api/forecast?as_of=`): one `ForecastMonth` per
/// calendar month from the as-of month to the cliff.
pub type Forecast {
  Forecast(months: List(ForecastMonth))
}

/// Encode a `ForecastMonth` (one month of the forecast) as a JSON object.
pub fn encode_forecast_month(month: ForecastMonth) -> Json {
  let ForecastMonth(month:, revenue:, cost:, profit:, margin_pct:) = month
  json.object([
    #("month", wire.encode_date(month)),
    #("revenue", json.float(revenue)),
    #("cost", json.float(cost)),
    #("profit", json.float(profit)),
    #("margin_pct", json.float(margin_pct)),
  ])
}

/// Decode a `ForecastMonth` from a JSON object.
pub fn forecast_month_decoder() -> Decoder(ForecastMonth) {
  use month <- decode.field("month", wire.date_decoder())
  use revenue <- decode.field("revenue", wire.lenient_float_decoder())
  use cost <- decode.field("cost", wire.lenient_float_decoder())
  use profit <- decode.field("profit", wire.lenient_float_decoder())
  use margin_pct <- decode.field("margin_pct", wire.lenient_float_decoder())
  decode.success(ForecastMonth(month:, revenue:, cost:, profit:, margin_pct:))
}

/// Encode a `Forecast` (the forecast read model) to JSON.
pub fn encode_forecast(forecast: Forecast) -> Json {
  let Forecast(months:) = forecast
  json.object([#("months", json.array(months, encode_forecast_month))])
}

/// Decode a `Forecast` from JSON.
pub fn forecast_decoder() -> Decoder(Forecast) {
  use months <- decode.field("months", decode.list(forecast_month_decoder()))
  decode.success(Forecast(months:))
}
