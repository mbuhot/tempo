//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/allocation/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// allocation_assign.sql — assert a fractional allocation over a bounded period,
/// contained by both employment and the project run via PERIOD FKs. Last param is the
/// audit_id. $1 = engineer_id, $2 = project_id, $3 = from, $4 = fraction, $5 = to.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_assign(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
  arg_3: Date,
  arg_4: Float,
  arg_5: Date,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_assign.sql — assert a fractional allocation over a bounded period,
-- contained by both employment and the project run via PERIOD FKs. Last param is the
-- audit_id. $1 = engineer_id, $2 = project_id, $3 = from, $4 = fraction, $5 = to.
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
VALUES ($1, $2, $4, daterange($3::date, $5::date, '[)'), $6);
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.calendar_date(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_change_fraction.sql — Change: re-fraction from a date onward. FOR
/// PORTION OF sets the new fraction + audit_id on [$3, row.upper); PG re-inserts the
/// [row.lower, $3) leftover at the old fraction keeping its original audit_id. The
/// `@> $3` filter excludes a scheduled future version. $1 = engineer_id,
/// $2 = project_id, $3 = effective, $4 = new fraction, $5 = audit_id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_change_fraction(
  db: pog.Connection,
  engineer_id: Int,
  project_id: Int,
  arg_3: Date,
  arg_4: Float,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_change_fraction.sql — Change: re-fraction from a date onward. FOR
-- PORTION OF sets the new fraction + audit_id on [$3, row.upper); PG re-inserts the
-- [row.lower, $3) leftover at the old fraction keeping its original audit_id. The
-- `@> $3` filter excludes a scheduled future version. $1 = engineer_id,
-- $2 = project_id, $3 = effective, $4 = new fraction, $5 = audit_id.
UPDATE allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
   SET fraction = $4, audit_id = $5
 WHERE engineer_id = $1 AND project_id = $2 AND allocated_during @> $3::date;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(project_id))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_close.sql — Close: cap one allocation at an end date.
///
/// Used by `roll_off`. `DELETE … FOR PORTION OF allocated_during FROM $3 TO NULL`
/// removes the [$3, ∞) tail of the matching allocation: a spanning row is capped to
/// [row.lower, $3) (Postgres re-inserts the before-leftover) and a fully-future row
/// is dropped outright. Keyed to a single engineer+project — no @> filter, so it
/// closes whatever future portion exists from $3 onward.
///
/// $1 = engineer_id, $2 = project_id, $3 = end day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_close(
  db: pog.Connection,
  engineer_id: Int,
  arg_2: Int,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_close.sql — Close: cap one allocation at an end date.
--
-- Used by `roll_off`. `DELETE … FOR PORTION OF allocated_during FROM $3 TO NULL`
-- removes the [$3, ∞) tail of the matching allocation: a spanning row is capped to
-- [row.lower, $3) (Postgres re-inserts the before-leftover) and a fully-future row
-- is dropped outright. Keyed to a single engineer+project — no @> filter, so it
-- closes whatever future portion exists from $3 onward.
--
-- $1 = engineer_id, $2 = project_id, $3 = end day (scalar date, cast in SQL).
DELETE FROM allocation
   FOR PORTION OF allocated_during FROM $3::date TO NULL
 WHERE engineer_id = $1 AND project_id = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(engineer_id))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// allocation_close_all.sql — Cascade: cap ALL of an engineer's allocations.
///
/// Used by `terminate_employment` as the allocation step of the child-first cascade.
/// `DELETE … FOR PORTION OF allocated_during FROM $2 TO NULL` wipes every future
/// allocation fact for the engineer from $2 onward: spanning rows are capped to
/// [row.lower, $2) and fully-future rows are dropped. The omitted @> filter is
/// deliberate — terminate is intentionally broad across all projects.
///
/// $1 = engineer_id, $2 = end day (scalar date, cast in SQL).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn allocation_close_all(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- allocation_close_all.sql — Cascade: cap ALL of an engineer's allocations.
--
-- Used by `terminate_employment` as the allocation step of the child-first cascade.
-- `DELETE … FOR PORTION OF allocated_during FROM $2 TO NULL` wipes every future
-- allocation fact for the engineer from $2 onward: spanning rows are capped to
-- [row.lower, $2) and fully-future rows are dropped. The omitted @> filter is
-- deliberate — terminate is intentionally broad across all projects.
--
-- $1 = engineer_id, $2 = end day (scalar date, cast in SQL).
DELETE FROM allocation
   FOR PORTION OF allocated_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
