//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/location/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `engineer_location_history` query
/// defined in `./src/tempo/server/location/sql/engineer_location_history.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerLocationHistoryRow {
  EngineerLocationHistoryRow(
    country: String,
    region: Option(String),
    timezone: String,
    valid_from: Date,
    valid_to: Date,
    ongoing: Bool,
  )
}

/// engineer_location_history.sql — all location spans for one engineer, oldest first.
/// Coalesced upper + upper_inf flag keep an open-ended span's NULL upper bound from
/// decoding as a non-null Date. $1 = engineer_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_location_history(
  db: pog.Connection,
  engineer_id: Int,
) -> Result(pog.Returned(EngineerLocationHistoryRow), pog.QueryError) {
  let decoder = {
    use country <- decode.field(0, decode.string)
    use region <- decode.field(1, decode.optional(decode.string))
    use timezone <- decode.field(2, decode.string)
    use valid_from <- decode.field(3, pog.calendar_date_decoder())
    use valid_to <- decode.field(4, pog.calendar_date_decoder())
    use ongoing <- decode.field(5, decode.bool)
    decode.success(EngineerLocationHistoryRow(
      country:,
      region:,
      timezone:,
      valid_from:,
      valid_to:,
      ongoing:,
    ))
  }

  "-- engineer_location_history.sql — all location spans for one engineer, oldest first.
-- Coalesced upper + upper_inf flag keep an open-ended span's NULL upper bound from
-- decoding as a non-null Date. $1 = engineer_id.
SELECT
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing
FROM engineer_location
WHERE engineer_id = $1
ORDER BY lower(located_during);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// engineer_location_upsert.sql — set an engineer's location from $2 onward. The temporal
/// DELETE clips the row covering $2 to [start, $2) and removes rows starting at/after $2,
/// then inserts [$2, NULL) with the new values, superseding scheduled future versions.
/// $1 engineer_id, $2 effective, $3 country, $4 region (empty string = none, stored NULL),
/// $5 timezone, $6 audit_id. `nullif` maps an absent region to NULL since Squirrel types the
/// INSERT value param as non-null text.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_location_upsert(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- engineer_location_upsert.sql — set an engineer's location from $2 onward. The temporal
-- DELETE clips the row covering $2 to [start, $2) and removes rows starting at/after $2,
-- then inserts [$2, NULL) with the new values, superseding scheduled future versions.
-- $1 engineer_id, $2 effective, $3 country, $4 region (empty string = none, stored NULL),
-- $5 timezone, $6 audit_id. `nullif` maps an absent region to NULL since Squirrel types the
-- INSERT value param as non-null text.
WITH deleted AS (
  DELETE FROM engineer_location
     FOR PORTION OF located_during FROM $2::date TO NULL
   WHERE engineer_id = $1
)
INSERT INTO engineer_location
  (engineer_id, located_during, country, region, timezone, audit_id)
VALUES ($1, daterange($2::date, NULL, '[)'), $3, nullif($4, ''), $5, $6);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_locations_asof` query
/// defined in `./src/tempo/server/location/sql/engineer_locations_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerLocationsAsofRow {
  EngineerLocationsAsofRow(
    engineer_id: Int,
    country: String,
    region: Option(String),
    timezone: String,
    valid_from: Date,
    valid_to: Date,
    ongoing: Bool,
  )
}

/// engineer_locations_asof.sql — the location in force on $1 for every engineer that has
/// one. Engineers without a location on that date are absent; the caller attaches them in
/// Gleam. Only NOT-NULL range bounds are selected (coalesced upper + upper_inf flag) so an
/// open-ended span decodes cleanly. $1 = as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_locations_asof(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(EngineerLocationsAsofRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.int)
    use country <- decode.field(1, decode.string)
    use region <- decode.field(2, decode.optional(decode.string))
    use timezone <- decode.field(3, decode.string)
    use valid_from <- decode.field(4, pog.calendar_date_decoder())
    use valid_to <- decode.field(5, pog.calendar_date_decoder())
    use ongoing <- decode.field(6, decode.bool)
    decode.success(EngineerLocationsAsofRow(
      engineer_id:,
      country:,
      region:,
      timezone:,
      valid_from:,
      valid_to:,
      ongoing:,
    ))
  }

  "-- engineer_locations_asof.sql — the location in force on $1 for every engineer that has
-- one. Engineers without a location on that date are absent; the caller attaches them in
-- Gleam. Only NOT-NULL range bounds are selected (coalesced upper + upper_inf flag) so an
-- open-ended span decodes cleanly. $1 = as-of date.
SELECT
  engineer_id,
  country,
  region,
  timezone,
  lower(located_during) AS valid_from,
  coalesce(upper(located_during), lower(located_during)) AS valid_to,
  upper_inf(located_during) AS ongoing
FROM engineer_location
WHERE located_during @> $1::date;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `engineer_roster` query
/// defined in `./src/tempo/server/location/sql/engineer_roster.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EngineerRosterRow {
  EngineerRosterRow(engineer_id: Option(Int), name: Option(String))
}

/// engineer_roster.sql — every current engineer (id + name), for listing pages that
/// attach as-of data (e.g. location) in the application layer.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn engineer_roster(
  db: pog.Connection,
) -> Result(pog.Returned(EngineerRosterRow), pog.QueryError) {
  let decoder = {
    use engineer_id <- decode.field(0, decode.optional(decode.int))
    use name <- decode.field(1, decode.optional(decode.string))
    decode.success(EngineerRosterRow(engineer_id:, name:))
  }

  "-- engineer_roster.sql — every current engineer (id + name), for listing pages that
-- attach as-of data (e.g. location) in the application layer.
SELECT id AS engineer_id, name
FROM engineer_current
ORDER BY name;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `timezone_valid` query
/// defined in `./src/tempo/server/location/sql/timezone_valid.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type TimezoneValidRow {
  TimezoneValidRow(valid: Bool)
}

/// timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn timezone_valid(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(TimezoneValidRow), pog.QueryError) {
  let decoder = {
    use valid <- decode.field(0, decode.bool)
    decode.success(TimezoneValidRow(valid:))
  }

  "-- timezone_valid.sql — whether $1 is a TZID PostgreSQL recognises. $1 = timezone.
SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1) AS valid;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
