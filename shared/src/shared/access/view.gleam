//// The read model for the Access management page (`GET /api/access`): the permission
//// catalog, the role catalog, the role->permission matrix in force as-of today, and
//// every account with the roles it currently holds. Defined in `shared` so the server
//// encodes and the client decodes the same shape. The client renders the matrix as a
//// roles-x-permissions grid and lists the users with grant/revoke controls.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}

pub type PermissionInfo {
  PermissionInfo(key: String, description: String)
}

pub type RoleInfo {
  RoleInfo(name: String, description: String)
}

/// One (role, permission) grant in force as-of today — a checked cell of the matrix.
pub type RoleGrant {
  RoleGrant(role: String, permission: String)
}

/// One account and the role names it currently holds (possibly none).
pub type UserRoles {
  UserRoles(
    account_id: Int,
    username: String,
    display_name: String,
    engineer_id: Option(Int),
    roles: List(String),
  )
}

pub type AccessSnapshot {
  AccessSnapshot(
    permissions: List(PermissionInfo),
    roles: List(RoleInfo),
    matrix: List(RoleGrant),
    users: List(UserRoles),
  )
}

pub fn encode_access_snapshot(snapshot: AccessSnapshot) -> Json {
  let AccessSnapshot(permissions:, roles:, matrix:, users:) = snapshot
  json.object([
    #("permissions", json.array(permissions, encode_permission_info)),
    #("roles", json.array(roles, encode_role_info)),
    #("matrix", json.array(matrix, encode_role_grant)),
    #("users", json.array(users, encode_user_roles)),
  ])
}

pub fn access_snapshot_decoder() -> Decoder(AccessSnapshot) {
  use permissions <- decode.field(
    "permissions",
    decode.list(permission_info_decoder()),
  )
  use roles <- decode.field("roles", decode.list(role_info_decoder()))
  use matrix <- decode.field("matrix", decode.list(role_grant_decoder()))
  use users <- decode.field("users", decode.list(user_roles_decoder()))
  decode.success(AccessSnapshot(permissions:, roles:, matrix:, users:))
}

fn encode_permission_info(info: PermissionInfo) -> Json {
  json.object([
    #("key", json.string(info.key)),
    #("description", json.string(info.description)),
  ])
}

fn permission_info_decoder() -> Decoder(PermissionInfo) {
  use key <- decode.field("key", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(PermissionInfo(key:, description:))
}

fn encode_role_info(info: RoleInfo) -> Json {
  json.object([
    #("name", json.string(info.name)),
    #("description", json.string(info.description)),
  ])
}

fn role_info_decoder() -> Decoder(RoleInfo) {
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(RoleInfo(name:, description:))
}

fn encode_role_grant(grant: RoleGrant) -> Json {
  json.object([
    #("role", json.string(grant.role)),
    #("permission", json.string(grant.permission)),
  ])
}

fn role_grant_decoder() -> Decoder(RoleGrant) {
  use role <- decode.field("role", decode.string)
  use permission <- decode.field("permission", decode.string)
  decode.success(RoleGrant(role:, permission:))
}

fn encode_user_roles(user: UserRoles) -> Json {
  json.object([
    #("account_id", json.int(user.account_id)),
    #("username", json.string(user.username)),
    #("display_name", json.string(user.display_name)),
    #("engineer_id", json.nullable(user.engineer_id, json.int)),
    #("roles", json.array(user.roles, json.string)),
  ])
}

fn user_roles_decoder() -> Decoder(UserRoles) {
  use account_id <- decode.field("account_id", decode.int)
  use username <- decode.field("username", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use engineer_id <- decode.field("engineer_id", decode.optional(decode.int))
  use roles <- decode.field("roles", decode.list(decode.string))
  decode.success(UserRoles(
    account_id:,
    username:,
    display_name:,
    engineer_id:,
    roles:,
  ))
}
