//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/account/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import pog

/// A row you get from running the `account_by_username` query
/// defined in `./src/tempo/server/account/sql/account_by_username.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type AccountByUsernameRow {
  AccountByUsernameRow(
    display_name: String,
    role: String,
    password_hash: String,
  )
}

/// account_by_username.sql — fetch a login account's display name, role, and password
/// hash by its unique username (an email). Drives POST /api/login: the handler verifies
/// the password against the hash and maps the role to a Principal. Returns 0 or 1 rows.
/// $1 = username.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn account_by_username(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(AccountByUsernameRow), pog.QueryError) {
  let decoder = {
    use display_name <- decode.field(0, decode.string)
    use role <- decode.field(1, decode.string)
    use password_hash <- decode.field(2, decode.string)
    decode.success(AccountByUsernameRow(display_name:, role:, password_hash:))
  }

  "-- account_by_username.sql — fetch a login account's display name, role, and password
-- hash by its unique username (an email). Drives POST /api/login: the handler verifies
-- the password against the hash and maps the role to a Principal. Returns 0 or 1 rows.
-- $1 = username.
SELECT display_name, role, password_hash
  FROM account
 WHERE username = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). Idempotent
/// via ON CONFLICT, so re-seeding never errors and never clobbers an existing row's
/// password. Never run by a migration: a deploy provisions real accounts itself.
/// $1 = username, $2 = display_name, $3 = role, $4 = password_hash (PHC string).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn account_upsert(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- account_upsert.sql — DEV-ONLY: provision a login account (tempo/seed). Idempotent
-- via ON CONFLICT, so re-seeding never errors and never clobbers an existing row's
-- password. Never run by a migration: a deploy provisions real accounts itself.
-- $1 = username, $2 = display_name, $3 = role, $4 = password_hash (PHC string).
INSERT INTO account (username, display_name, role, password_hash)
VALUES ($1, $2, $3, $4)
ON CONFLICT (username) DO NOTHING;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
