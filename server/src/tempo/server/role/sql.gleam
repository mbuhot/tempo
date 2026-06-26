//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/role/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/calendar.{type Date}
import pog

/// user_role_grant.sql — grant a role to an account effective from a date (GrantUserRole).
/// Caps any current period at the effective date then opens a fresh [effective, ∞), so a
/// re-grant is idempotent — mirroring engineer_role_upsert's close-then-open. $1 = account
/// id, $2 = role, $3 = effective date, $4 = audit_id (the journal event for this grant).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn user_role_grant(
  db: pog.Connection,
  account_id: Int,
  role: String,
  arg_3: Date,
  arg_4: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- user_role_grant.sql — grant a role to an account effective from a date (GrantUserRole).
-- Caps any current period at the effective date then opens a fresh [effective, ∞), so a
-- re-grant is idempotent — mirroring engineer_role_upsert's close-then-open. $1 = account
-- id, $2 = role, $3 = effective date, $4 = audit_id (the journal event for this grant).
WITH capped AS (
  DELETE FROM user_role
     FOR PORTION OF held_during FROM $3::date TO NULL
   WHERE account_id = $1 AND role = $2
)
INSERT INTO user_role (account_id, role, held_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
"
  |> pog.query
  |> pog.parameter(pog.int(account_id))
  |> pog.parameter(pog.text(role))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// user_role_revoke.sql — revoke a role from an account effective from a date
/// (RevokeUserRole): cap the held period at the effective date (DELETE FOR PORTION OF),
/// leaving the history [start, effective) intact for audit. $1 = account id, $2 = role,
/// $3 = effective date.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn user_role_revoke(
  db: pog.Connection,
  account_id: Int,
  arg_2: String,
  arg_3: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- user_role_revoke.sql — revoke a role from an account effective from a date
-- (RevokeUserRole): cap the held period at the effective date (DELETE FOR PORTION OF),
-- leaving the history [start, effective) intact for audit. $1 = account id, $2 = role,
-- $3 = effective date.
DELETE FROM user_role
   FOR PORTION OF held_during FROM $3::date TO NULL
 WHERE account_id = $1 AND role = $2;
"
  |> pog.query
  |> pog.parameter(pog.int(account_id))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.calendar_date(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
