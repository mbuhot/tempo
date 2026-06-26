//// The forecast read models and their JSON codecs: one `ForecastMonth` of
//// projected revenue/cost/profit and the whole `Forecast` series. Pure Gleam, no
//// target-specific deps, so they round-trip on both ends of the JSON-over-HTTP
//// boundary. Dates serialise as ISO-8601 "YYYY-MM-DD" strings; money/margin
//// fields decode leniently.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import shared/money.{type Money}
import shared/wire

/// One month of the forecast (`GET /api/forecast?as_of=`): the first-of-`month`
/// Date (the client formats it) and the projected `revenue`, `cost`, `profit`, and
/// `margin_pct` from committed demand for that month.
pub type ForecastMonth {
  ForecastMonth(
    month: Date,
    revenue: Money,
    cost: Money,
    profit: Money,
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
    #("revenue", money.encode(revenue)),
    #("cost", money.encode(cost)),
    #("profit", money.encode(profit)),
    #("margin_pct", json.float(margin_pct)),
  ])
}

/// Decode a `ForecastMonth` from a JSON object.
pub fn forecast_month_decoder() -> Decoder(ForecastMonth) {
  use month <- decode.field("month", wire.date_decoder())
  use revenue <- decode.field("revenue", money.decoder())
  use cost <- decode.field("cost", money.decoder())
  use profit <- decode.field("profit", money.decoder())
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
