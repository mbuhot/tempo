//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/rate_card/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `contract_rate_upsert` query
/// defined in `./src/tempo/server/rate_card/sql/contract_rate_upsert.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ContractRateUpsertRow {
  ContractRateUpsertRow(contract_id: Int)
}

/// contract_rate_upsert.sql — record the contract's own day rate for a level from
/// $4 onward (delete-then-insert semantics, like engineer_role_upsert). The
/// temporal DELETE clips the row covering $4 to [start, $4) and removes any rows
/// that start at or after $4, then the INSERT opens a new row bounded by the
/// covering contract_terms row's own end — clipping the "open-ended from $4
/// onward" Change to the signed term keeps the contract_rate_within_term PERIOD FK
/// satisfiable while preserving open-ended-within-the-term semantics.
/// $1 = contract_id, $2 = level, $3 = new rate (exact decimal text, cast to
/// numeric), $4 = effective, $5 = audit_id.
///
/// With no signed term covering $4, the INSERT ... SELECT matches nothing and
/// RETURNING yields zero rows; the repository rejects that (NoSuchVersion) rather
/// than journalling a silent no-op.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn contract_rate_upsert(
  db: pog.Connection,
  contract_id: Int,
  level: Int,
  arg_3: String,
  arg_4: Date,
  arg_5: Int,
) -> Result(pog.Returned(ContractRateUpsertRow), pog.QueryError) {
  let decoder = {
    use contract_id <- decode.field(0, decode.int)
    decode.success(ContractRateUpsertRow(contract_id:))
  }

  "-- contract_rate_upsert.sql — record the contract's own day rate for a level from
-- $4 onward (delete-then-insert semantics, like engineer_role_upsert). The
-- temporal DELETE clips the row covering $4 to [start, $4) and removes any rows
-- that start at or after $4, then the INSERT opens a new row bounded by the
-- covering contract_terms row's own end — clipping the \"open-ended from $4
-- onward\" Change to the signed term keeps the contract_rate_within_term PERIOD FK
-- satisfiable while preserving open-ended-within-the-term semantics.
-- $1 = contract_id, $2 = level, $3 = new rate (exact decimal text, cast to
-- numeric), $4 = effective, $5 = audit_id.
--
-- With no signed term covering $4, the INSERT ... SELECT matches nothing and
-- RETURNING yields zero rows; the repository rejects that (NoSuchVersion) rather
-- than journalling a silent no-op.
WITH term AS (
  SELECT upper(term) AS term_end
  FROM contract_terms
  WHERE contract_id = $1 AND term @> $4::date
),
deleted AS (
  DELETE FROM contract_rate
    FOR PORTION OF effective_during FROM $4::date TO NULL
  WHERE contract_id = $1 AND level = $2
)
INSERT INTO contract_rate (contract_id, level, day_rate, effective_during, audit_id)
SELECT $1, $2, $3::text::numeric, daterange($4::date, term.term_end, '[)'), $5
FROM term
RETURNING contract_id;
"
  |> pog.query
  |> pog.parameter(pog.int(contract_id))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.calendar_date(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// rate_card_for_portion_of.sql — surgical charge-rate edit. FOR PORTION OF splits the
/// covering rate_card row, setting day_rate + audit_id only on [$1, $2) and carving
/// off the unchanged before/after remainders keeping their original audit_id.
/// $1 = from, $2 = to, $3 = new rate (exact decimal text, cast to numeric),
/// $4 = level, $5 = audit_id.
///
/// PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
/// from the affected-row count — read the rows back instead.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_for_portion_of(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
  arg_3: String,
  arg_4: Int,
  audit_id: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- rate_card_for_portion_of.sql — surgical charge-rate edit. FOR PORTION OF splits the
-- covering rate_card row, setting day_rate + audit_id only on [$1, $2) and carving
-- off the unchanged before/after remainders keeping their original audit_id.
-- $1 = from, $2 = to, $3 = new rate (exact decimal text, cast to numeric),
-- $4 = level, $5 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces extra rows, so never infer a split
-- from the affected-row count — read the rows back instead.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO $2::date
   SET day_rate = $3::text::numeric, audit_id = $5
 WHERE level = $4;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `rate_card_list` query
/// defined in `./src/tempo/server/rate_card/sql/rate_card_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RateCardListRow {
  RateCardListRow(level: Int, day_rate: String)
}

/// rate_card_list.sql — the current charge rate per level as of $1 (GET
/// /api/settings?as_of=$1; the rate-card table on the Settings page; FR-ST1). One
/// row per level whose rate_card span covers $1: level + day_rate, ordered by level.
/// A level with no rate covering $1 is simply absent. Param: $1 = the as-of date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_list(
  db: pog.Connection,
  arg_1: Date,
) -> Result(pog.Returned(RateCardListRow), pog.QueryError) {
  let decoder = {
    use level <- decode.field(0, decode.int)
    use day_rate <- decode.field(1, decode.string)
    decode.success(RateCardListRow(level:, day_rate:))
  }

  "-- rate_card_list.sql — the current charge rate per level as of $1 (GET
-- /api/settings?as_of=$1; the rate-card table on the Settings page; FR-ST1). One
-- row per level whose rate_card span covers $1: level + day_rate, ordered by level.
-- A level with no rate covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  rate_card.level,
  rate_card.day_rate::text AS day_rate
FROM rate_card
WHERE rate_card.effective_during @> $1::date
ORDER BY rate_card.level;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `rate_card_revise` query
/// defined in `./src/tempo/server/rate_card/sql/rate_card_revise.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RateCardReviseRow {
  RateCardReviseRow(revised: Int)
}

/// rate_card_revise.sql — change a level's day_rate from $1 onward (Change). FOR
/// PORTION OF re-rates [$1, ∞) of the covering row, setting day_rate + audit_id; PG
/// carves off the unchanged [start, $1) remainder keeping its original audit_id. The
/// `@>` guard leaves a scheduled future version untouched. $1 = effective,
/// $2 = new rate (exact decimal text, cast to numeric), $3 = level, $4 = audit_id.
///
/// PG reports `UPDATE 1` even when it produces an extra remainder row, so never
/// infer a split from the affected-row count — read the rows back instead. With no
/// covering version the UPDATE matches nothing and RETURNING yields zero rows; the
/// repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn rate_card_revise(
  db: pog.Connection,
  arg_1: Date,
  arg_2: String,
  level: Int,
  audit_id: Int,
) -> Result(pog.Returned(RateCardReviseRow), pog.QueryError) {
  let decoder = {
    use revised <- decode.field(0, decode.int)
    decode.success(RateCardReviseRow(revised:))
  }

  "-- rate_card_revise.sql — change a level's day_rate from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting day_rate + audit_id; PG
-- carves off the unchanged [start, $1) remainder keeping its original audit_id. The
-- `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new rate (exact decimal text, cast to numeric), $3 = level, $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead. With no
-- covering version the UPDATE matches nothing and RETURNING yields zero rows; the
-- repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
UPDATE rate_card
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET day_rate = $2::text::numeric, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date
RETURNING 1 AS revised;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.int(level))
  |> pog.parameter(pog.int(audit_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
