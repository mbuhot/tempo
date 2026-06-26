//// Domain: authenticate a login (read side of the `account` concept). Look up the
//// account by username, verify the supplied password against its stored hash, and map
//// the stored role to an `auth.Role` — yielding the same `Principal` the rest of the
//// app already keys on. No HTTP (never imports wisp): the web login handler turns the
//// typed result into a signed session cookie or a uniform 401. The distinct error
//// variants are for tests/logging; the handler collapses the client-visible ones into
//// one "invalid username or password" so login leaks no account oracle.

import gleam/result
import pog
import tempo/server/account/password as hashing
import tempo/server/account/sql
import tempo/server/auth.{type Principal, Principal}

/// Why authentication failed. Only `StoreError` is a server fault (→ 5xx); the rest are
/// client-visible as one uniform 401 so an attacker cannot tell a bad password from an
/// unknown user. `CorruptAccount` is a seeded/migrated row whose role is not a known
/// role — a data bug, not a credential the client controls.
pub type AuthnError {
  UnknownUser
  BadPassword
  CorruptAccount
  StoreError(error: pog.QueryError)
}

/// Authenticate `username`/`password` against the `account` table, returning the
/// `Principal` (display name + role) to seat in the session on success.
pub fn authenticate(
  db: pog.Connection,
  username: String,
  password: String,
) -> Result(Principal, AuthnError) {
  use returned <- result.try(
    sql.account_by_username(db, username)
    |> result.map_error(StoreError),
  )
  case returned.rows {
    [] -> Error(UnknownUser)
    [row, ..] -> verify_account(row, password)
  }
}

fn verify_account(
  row: sql.AccountByUsernameRow,
  password: String,
) -> Result(Principal, AuthnError) {
  case auth.role_from_string(row.role) {
    Error(Nil) -> Error(CorruptAccount)
    Ok(role) ->
      case hashing.verify(row.password_hash, password) {
        True -> Ok(Principal(actor: row.display_name, role:))
        False -> Error(BadPassword)
      }
  }
}
