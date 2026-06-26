//// Domain: authenticate a login (read side of the `account` concept). Look up the
//// account by username and verify the supplied password against its stored hash,
//// returning the account's identity — its id (seated in the session cookie), journal
//// display name, and linked engineer (for ownership). Roles/permissions are NOT here:
//// they live in the temporal `user_role`/`role_permission` maps and are resolved per
//// request by `access.resolve`. No HTTP (never imports wisp); the web login handler
//// turns the typed result into a session cookie or a uniform 401.

import gleam/option.{type Option}
import gleam/result
import pog
import tempo/server/account/password as hashing
import tempo/server/account/sql

/// An authenticated account: its id, journal display name, and linked engineer (`None`
/// for a non-engineer account).
pub type Account {
  Account(id: Int, display_name: String, engineer_id: Option(Int))
}

/// Why authentication failed. Only `StoreError` is a server fault (→ 5xx); `UnknownUser`
/// and `BadPassword` are client-visible as one uniform 401 so login leaks no oracle for
/// which accounts exist.
pub type AuthnError {
  UnknownUser
  BadPassword
  StoreError(error: pog.QueryError)
}

/// Authenticate `username`/`password` against the `account` table, returning the
/// account identity on success.
pub fn authenticate(
  db: pog.Connection,
  username: String,
  password: String,
) -> Result(Account, AuthnError) {
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
) -> Result(Account, AuthnError) {
  case hashing.verify(row.password_hash, password) {
    True ->
      Ok(Account(
        id: row.id,
        display_name: row.display_name,
        engineer_id: row.engineer_id,
      ))
    False -> Error(BadPassword)
  }
}
