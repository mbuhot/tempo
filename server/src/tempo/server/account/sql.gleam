//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/account/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import pog

/// A row you get from running the `account_by_id` query
/// defined in `./src/tempo/server/account/sql/account_by_id.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type AccountByIdRow {
  AccountByIdRow(display_name: String, engineer_id: Option(Int))
}

/// account_by_id.sql — the journal display name and linked engineer for an account id
/// (the id carried in the signed session cookie). Used to build the request Principal
/// before resolving its effective permissions. Returns 0 or 1 rows. $1 = account id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn account_by_id(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(AccountByIdRow), pog.QueryError) {
  let decoder = {
    use display_name <- decode.field(0, decode.string)
    use engineer_id <- decode.field(1, decode.optional(decode.int))
    decode.success(AccountByIdRow(display_name:, engineer_id:))
  }

  "-- account_by_id.sql — the journal display name and linked engineer for an account id
-- (the id carried in the signed session cookie). Used to build the request Principal
-- before resolving its effective permissions. Returns 0 or 1 rows. $1 = account id.
SELECT display_name, engineer_id
  FROM account
 WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `account_by_username` query
/// defined in `./src/tempo/server/account/sql/account_by_username.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type AccountByUsernameRow {
  AccountByUsernameRow(
    id: Int,
    display_name: String,
    engineer_id: Option(Int),
    password_hash: String,
  )
}

/// account_by_username.sql — fetch a login account by its unique username (an email):
/// id, display name, linked engineer (nullable), and password hash. Drives POST
/// /api/login. Returns 0 or 1 rows. $1 = username.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn account_by_username(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(AccountByUsernameRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use display_name <- decode.field(1, decode.string)
    use engineer_id <- decode.field(2, decode.optional(decode.int))
    use password_hash <- decode.field(3, decode.string)
    decode.success(AccountByUsernameRow(
      id:,
      display_name:,
      engineer_id:,
      password_hash:,
    ))
  }

  "-- account_by_username.sql — fetch a login account by its unique username (an email):
-- id, display name, linked engineer (nullable), and password hash. Drives POST
-- /api/login. Returns 0 or 1 rows. $1 = username.
SELECT id, display_name, engineer_id, password_hash
  FROM account
 WHERE username = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). engineer_id is
/// derived from the username when it matches an engineer's email (NULL otherwise), so a
/// person's account links to their engineer record for ownership checks. Idempotent via
/// ON CONFLICT, so re-seeding never errors and never clobbers an existing row.
/// $1 = username, $2 = display_name, $3 = password_hash.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn account_upsert(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). engineer_id is
-- derived from the username when it matches an engineer's email (NULL otherwise), so a
-- person's account links to their engineer record for ownership checks. Idempotent via
-- ON CONFLICT, so re-seeding never errors and never clobbers an existing row.
-- $1 = username, $2 = display_name, $3 = password_hash.
INSERT INTO account (username, display_name, engineer_id, password_hash)
SELECT $1, $2, (SELECT id FROM engineer_current WHERE email = $1), $3
ON CONFLICT (username) DO NOTHING;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
