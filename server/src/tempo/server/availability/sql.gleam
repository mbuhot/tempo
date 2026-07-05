//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/availability/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `focus_block_delete` query
/// defined in `./src/tempo/server/availability/sql/focus_block_delete.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type FocusBlockDeleteRow {
  FocusBlockDeleteRow(id: Int)
}

/// focus_block_delete.sql — drop a focus block its claimed owner holds. $1 focus_block_id,
/// $2 engineer_id. RETURNING gates a missing or foreign block.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn focus_block_delete(
  db: pog.Connection,
  id: Int,
  engineer_id: Int,
) -> Result(pog.Returned(FocusBlockDeleteRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(FocusBlockDeleteRow(id:))
  }

  "-- focus_block_delete.sql — drop a focus block its claimed owner holds. $1 focus_block_id,
-- $2 engineer_id. RETURNING gates a missing or foreign block.
DELETE FROM focus_block WHERE id = $1 AND engineer_id = $2 RETURNING id;
"
  |> pog.query
  |> pog.parameter(pog.int(id))
  |> pog.parameter(pog.int(engineer_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// focus_block_insert.sql — add a focus block. $1 engineer_id, $2 date, $3 starts (HH:MM),
/// $4 duration_minutes, $5 timezone, $6 title, $7 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn focus_block_insert(
  db: pog.Connection,
  arg_1: Int,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- focus_block_insert.sql — add a focus block. $1 engineer_id, $2 date, $3 starts (HH:MM),
-- $4 duration_minutes, $5 timezone, $6 title, $7 audit_id.
INSERT INTO focus_block (engineer_id, busy_at, title, audit_id)
VALUES ($1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $6, $7);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `focus_blocks_upcoming` query
/// defined in `./src/tempo/server/availability/sql/focus_blocks_upcoming.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type FocusBlocksUpcomingRow {
  FocusBlocksUpcomingRow(
    id: Int,
    title: String,
    starts_at: String,
    ends_at: String,
    offset_minutes: Option(Int),
  )
}

/// focus_blocks_upcoming.sql — one engineer's focus blocks ending on/after $2, with the
/// block's UTC offset in the engineer's location timezone as-of $2 (NULL when unlocated).
/// $1 engineer_id, $2 as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn focus_blocks_upcoming(
  db: pog.Connection,
  f_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(FocusBlocksUpcomingRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use starts_at <- decode.field(2, decode.string)
    use ends_at <- decode.field(3, decode.string)
    use offset_minutes <- decode.field(4, decode.optional(decode.int))
    decode.success(FocusBlocksUpcomingRow(
      id:,
      title:,
      starts_at:,
      ends_at:,
      offset_minutes:,
    ))
  }

  "-- focus_blocks_upcoming.sql — one engineer's focus blocks ending on/after $2, with the
-- block's UTC offset in the engineer's location timezone as-of $2 (NULL when unlocated).
-- $1 engineer_id, $2 as_of.
SELECT f.id AS id,
       f.title AS title,
       to_char(lower(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS starts_at,
       to_char(upper(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS ends_at,
       ((extract(epoch from (lower(f.busy_at) AT TIME ZONE loc.timezone))
         - extract(epoch from (lower(f.busy_at) AT TIME ZONE 'UTC'))) / 60)::int AS \"offset_minutes?\"
FROM focus_block f
LEFT JOIN engineer_location loc
       ON loc.engineer_id = f.engineer_id AND loc.located_during @> $2::date
WHERE f.engineer_id = $1 AND upper(f.busy_at) >= $2::date
ORDER BY lower(f.busy_at), f.id;
"
  |> pog.query
  |> pog.parameter(pog.int(f_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `holiday_region_exists` query
/// defined in `./src/tempo/server/availability/sql/holiday_region_exists.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type HolidayRegionExistsRow {
  HolidayRegionExistsRow(known: Bool)
}

/// holiday_region_exists.sql — whether ($1, $2) names a known region. $1 country, $2 region.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn holiday_region_exists(
  db: pog.Connection,
  country: String,
  arg_2: String,
) -> Result(pog.Returned(HolidayRegionExistsRow), pog.QueryError) {
  let decoder = {
    use known <- decode.field(0, decode.bool)
    decode.success(HolidayRegionExistsRow(known:))
  }

  "-- holiday_region_exists.sql — whether ($1, $2) names a known region. $1 country, $2 region.
SELECT EXISTS (SELECT 1 FROM holiday_region WHERE country = $1 AND region = $2) AS known;
"
  |> pog.query
  |> pog.parameter(pog.text(country))
  |> pog.parameter(pog.text(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// holiday_upsert.sql — import one holiday row. $1 country, $2 region ('' = nationwide),
/// $3 date, $4 name, $5 audit_id. Re-import refreshes the name.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn holiday_upsert(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: Date,
  arg_4: String,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- holiday_upsert.sql — import one holiday row. $1 country, $2 region ('' = nationwide),
-- $3 date, $4 name, $5 audit_id. Re-import refreshes the name.
INSERT INTO holiday (country, region, holiday_on, name, audit_id)
VALUES ($1, $2, $3::date, $4, $5)
ON CONFLICT (country, region, holiday_on)
DO UPDATE SET name = EXCLUDED.name, audit_id = EXCLUDED.audit_id;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `holidays_for_engineer` query
/// defined in `./src/tempo/server/availability/sql/holidays_for_engineer.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type HolidaysForEngineerRow {
  HolidaysForEngineerRow(holiday_on: Date, name: String)
}

/// holidays_for_engineer.sql — next 10 holidays for the engineer's location as-of $2;
/// nationwide ('') and subdivision rows both match. $1 engineer_id, $2 as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn holidays_for_engineer(
  db: pog.Connection,
  loc_engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(HolidaysForEngineerRow), pog.QueryError) {
  let decoder = {
    use holiday_on <- decode.field(0, pog.calendar_date_decoder())
    use name <- decode.field(1, decode.string)
    decode.success(HolidaysForEngineerRow(holiday_on:, name:))
  }

  "-- holidays_for_engineer.sql — next 10 holidays for the engineer's location as-of $2;
-- nationwide ('') and subdivision rows both match. $1 engineer_id, $2 as_of.
SELECT h.holiday_on AS holiday_on, h.name AS name
FROM engineer_location loc
JOIN holiday h ON h.country = loc.country AND h.region IN ('', loc.region)
WHERE loc.engineer_id = $1 AND loc.located_during @> $2::date
  AND h.holiday_on >= $2::date
ORDER BY h.holiday_on
LIMIT 10;
"
  |> pog.query
  |> pog.parameter(pog.int(loc_engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `holidays_upcoming` query
/// defined in `./src/tempo/server/availability/sql/holidays_upcoming.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type HolidaysUpcomingRow {
  HolidaysUpcomingRow(
    country: String,
    region: String,
    region_name: String,
    holiday_on: Date,
    name: String,
  )
}

/// holidays_upcoming.sql — all holidays on/after $1 with their region names. $1 as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn holidays_upcoming(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(HolidaysUpcomingRow), pog.QueryError) {
  let decoder = {
    use country <- decode.field(0, decode.string)
    use region <- decode.field(1, decode.string)
    use region_name <- decode.field(2, decode.string)
    use holiday_on <- decode.field(3, pog.calendar_date_decoder())
    use name <- decode.field(4, decode.string)
    decode.success(HolidaysUpcomingRow(
      country:,
      region:,
      region_name:,
      holiday_on:,
      name:,
    ))
  }

  "-- holidays_upcoming.sql — all holidays on/after $1 with their region names. $1 as_of.
SELECT h.country AS country, h.region AS region, r.name AS region_name,
       h.holiday_on AS holiday_on, h.name AS name
FROM holiday h
JOIN holiday_region r ON r.country = h.country AND r.region = h.region
WHERE h.holiday_on >= $1::date
ORDER BY h.holiday_on, h.country, h.region;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `timezone_valid` query
/// defined in `./src/tempo/server/availability/sql/timezone_valid.sql`.
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

/// A row you get from running the `work_schedule_asof` query
/// defined in `./src/tempo/server/availability/sql/work_schedule_asof.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type WorkScheduleAsofRow {
  WorkScheduleAsofRow(weekday: Int, starts: String, ends: String)
}

/// work_schedule_asof.sql — one engineer's weekday hours covering $2. $1 engineer_id, $2 as_of.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn work_schedule_asof(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Date,
) -> Result(pog.Returned(WorkScheduleAsofRow), pog.QueryError) {
  let decoder = {
    use weekday <- decode.field(0, decode.int)
    use starts <- decode.field(1, decode.string)
    use ends <- decode.field(2, decode.string)
    decode.success(WorkScheduleAsofRow(weekday:, starts:, ends:))
  }

  "-- work_schedule_asof.sql — one engineer's weekday hours covering $2. $1 engineer_id, $2 as_of.
SELECT weekday,
       to_char(starts, 'HH24:MI') AS starts,
       to_char(ends, 'HH24:MI') AS ends
FROM work_schedule
WHERE engineer_id = $1 AND valid_at @> $2::date
ORDER BY weekday;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// work_schedule_clear.sql — clear one weekday's hours from a date. $1 engineer_id,
/// $2 weekday, $3 effective.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn work_schedule_clear(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- work_schedule_clear.sql — clear one weekday's hours from a date. $1 engineer_id,
-- $2 weekday, $3 effective.
DELETE FROM work_schedule
   FOR PORTION OF valid_at FROM $3::date TO NULL
 WHERE engineer_id = $1 AND weekday = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// work_schedule_upsert.sql — set one weekday's hours from a date. $1 engineer_id,
/// $2 weekday (0=Mon), $3 effective, $4 starts (HH:MM), $5 ends (HH:MM), $6 audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn work_schedule_upsert(
  db: pog.Connection,
  engineer_id: Int,
  weekday: Int,
  arg_3: Date,
  arg_4: String,
  arg_5: String,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- work_schedule_upsert.sql — set one weekday's hours from a date. $1 engineer_id,
-- $2 weekday (0=Mon), $3 effective, $4 starts (HH:MM), $5 ends (HH:MM), $6 audit_id.
WITH deleted AS (
  DELETE FROM work_schedule
     FOR PORTION OF valid_at FROM $3::date TO NULL
   WHERE engineer_id = $1 AND weekday = $2
)
INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), ($4::text)::time, ($5::text)::time, $6);
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(weekday))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
