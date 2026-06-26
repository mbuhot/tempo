//// Domain (read side of access control): resolve a request `Principal` from the account
//// id carried in the signed session cookie — its journal display name, linked engineer,
//// and the permission keys it holds as-of today (the union of role_permission over every
//// role held) — and assemble the Access management page snapshot (the role->permission
//// matrix and every account's current roles). No HTTP — never imports `wisp`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import pog
import shared/access/view.{
  type AccessSnapshot, type UserRoles, AccessSnapshot, PermissionInfo, RoleGrant,
  RoleInfo, UserRoles,
}
import tempo/server/access/sql
import tempo/server/account/sql as account_sql
import tempo/server/auth.{type Principal, Principal}
import tempo/server/context.{type Context}

/// Build the `Principal` for an authenticated account id: its display name and linked
/// engineer, plus its effective permissions resolved as-of today. `Error(Nil)` when the
/// account no longer exists or a lookup fails — every "not authenticated" case the web
/// layer turns into a 401.
pub fn resolve(context: Context, account_id: Int) -> Result(Principal, Nil) {
  use #(display_name, engineer_id) <- result.try(load_account(
    context.db,
    account_id,
  ))
  use permissions <- result.map(load_permissions(context.db, account_id))
  Principal(account_id:, actor: display_name, engineer_id:, permissions:)
}

fn load_account(
  db: pog.Connection,
  account_id: Int,
) -> Result(#(String, Option(Int)), Nil) {
  case account_sql.account_by_id(db, account_id) {
    Ok(returned) ->
      case returned.rows {
        [row, ..] -> Ok(#(row.display_name, row.engineer_id))
        [] -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn load_permissions(
  db: pog.Connection,
  account_id: Int,
) -> Result(Set(String), Nil) {
  case sql.effective_permissions(db, account_id) {
    Ok(returned) ->
      Ok(set.from_list(list.map(returned.rows, fn(row) { row.permission })))
    Error(_) -> Error(Nil)
  }
}

/// Assemble the Access page snapshot: the permission catalog and role catalog (matrix
/// labels), the (role, permission) grants in force today (the checked cells), and every
/// account with the roles it currently holds.
pub fn snapshot(context: Context) -> Result(AccessSnapshot, pog.QueryError) {
  use permissions <- result.try(sql.permission_catalog(context.db))
  use roles <- result.try(sql.role_catalog(context.db))
  use matrix <- result.try(sql.role_matrix(context.db))
  use users <- result.map(sql.users_with_roles(context.db))
  AccessSnapshot(
    permissions: list.map(permissions.rows, fn(row) {
      PermissionInfo(key: row.key, description: row.description)
    }),
    roles: list.map(roles.rows, fn(row) {
      RoleInfo(name: row.name, description: row.description)
    }),
    matrix: list.map(matrix.rows, fn(row) {
      RoleGrant(role: row.role, permission: row.permission)
    }),
    users: group_users(users.rows),
  )
}

/// Fold the (account, role) rows — ordered so an account's rows are adjacent — into one
/// `UserRoles` per account, collecting its non-null roles.
fn group_users(rows: List(sql.UsersWithRolesRow)) -> List(UserRoles) {
  rows
  |> list.fold([], fn(grouped: List(UserRoles), row) {
    case grouped {
      [last, ..rest] if last.account_id == row.id -> [
        UserRoles(..last, roles: extend(last.roles, row.role)),
        ..rest
      ]
      _ -> [
        UserRoles(
          account_id: row.id,
          username: row.username,
          display_name: row.display_name,
          engineer_id: row.engineer_id,
          roles: role_list(row.role),
        ),
        ..grouped
      ]
    }
  })
  |> list.reverse
}

fn role_list(role: Option(String)) -> List(String) {
  case role {
    Some(name) -> [name]
    None -> []
  }
}

fn extend(roles: List(String), role: Option(String)) -> List(String) {
  case role {
    Some(name) -> list.append(roles, [name])
    None -> roles
  }
}
