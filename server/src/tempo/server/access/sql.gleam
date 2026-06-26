//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/access/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import pog

/// A row you get from running the `effective_permissions` query
/// defined in `./src/tempo/server/access/sql/effective_permissions.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EffectivePermissionsRow {
  EffectivePermissionsRow(permission: String)
}

/// effective_permissions.sql — the set of permission keys an account holds RIGHT NOW:
/// the union of role_permission over every role the account holds, both periods covering
/// CURRENT_DATE. The authorization gate checks each command/read permission against this
/// set. $1 = account id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn effective_permissions(
  db: pog.Connection,
  ur_account_id: Int,
) -> Result(pog.Returned(EffectivePermissionsRow), pog.QueryError) {
  let decoder = {
    use permission <- decode.field(0, decode.string)
    decode.success(EffectivePermissionsRow(permission:))
  }

  "-- effective_permissions.sql — the set of permission keys an account holds RIGHT NOW:
-- the union of role_permission over every role the account holds, both periods covering
-- CURRENT_DATE. The authorization gate checks each command/read permission against this
-- set. $1 = account id.
SELECT DISTINCT rp.permission
  FROM user_role ur
  JOIN role_permission rp ON rp.role = ur.role
 WHERE ur.account_id = $1
   AND ur.held_during @> CURRENT_DATE
   AND rp.granted_during @> CURRENT_DATE;
"
  |> pog.query
  |> pog.parameter(pog.int(ur_account_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `permission_catalog` query
/// defined in `./src/tempo/server/access/sql/permission_catalog.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PermissionCatalogRow {
  PermissionCatalogRow(key: String, description: String)
}

/// permission_catalog.sql — every permission key + description, for the Access matrix
/// view's row labels.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn permission_catalog(
  db: pog.Connection,
) -> Result(pog.Returned(PermissionCatalogRow), pog.QueryError) {
  let decoder = {
    use key <- decode.field(0, decode.string)
    use description <- decode.field(1, decode.string)
    decode.success(PermissionCatalogRow(key:, description:))
  }

  "-- permission_catalog.sql — every permission key + description, for the Access matrix
-- view's row labels.
SELECT key, description FROM permission ORDER BY key;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `role_catalog` query
/// defined in `./src/tempo/server/access/sql/role_catalog.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RoleCatalogRow {
  RoleCatalogRow(name: String, description: String)
}

/// role_catalog.sql — every role + description, for the Access matrix view's columns.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn role_catalog(
  db: pog.Connection,
) -> Result(pog.Returned(RoleCatalogRow), pog.QueryError) {
  let decoder = {
    use name <- decode.field(0, decode.string)
    use description <- decode.field(1, decode.string)
    decode.success(RoleCatalogRow(name:, description:))
  }

  "-- role_catalog.sql — every role + description, for the Access matrix view's columns.
SELECT name, description FROM role ORDER BY name;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `role_matrix` query
/// defined in `./src/tempo/server/access/sql/role_matrix.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type RoleMatrixRow {
  RoleMatrixRow(role: String, permission: String)
}

/// role_matrix.sql — the (role, permission) grants in force as-of CURRENT_DATE: the matrix
/// the Access page renders. The client groups rows by role.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn role_matrix(
  db: pog.Connection,
) -> Result(pog.Returned(RoleMatrixRow), pog.QueryError) {
  let decoder = {
    use role <- decode.field(0, decode.string)
    use permission <- decode.field(1, decode.string)
    decode.success(RoleMatrixRow(role:, permission:))
  }

  "-- role_matrix.sql — the (role, permission) grants in force as-of CURRENT_DATE: the matrix
-- the Access page renders. The client groups rows by role.
SELECT rp.role, rp.permission
  FROM role_permission rp
 WHERE rp.granted_during @> CURRENT_DATE
 ORDER BY rp.role, rp.permission;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `users_with_roles` query
/// defined in `./src/tempo/server/access/sql/users_with_roles.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type UsersWithRolesRow {
  UsersWithRolesRow(
    id: Int,
    username: String,
    display_name: String,
    engineer_id: Option(Int),
    role: Option(String),
  )
}

/// users_with_roles.sql — every account with the roles it holds as-of CURRENT_DATE (one
/// row per account/role; an account with no current role yields a single row with a NULL
/// role). The Access page groups rows into one entry per account. $1 has no params.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn users_with_roles(
  db: pog.Connection,
) -> Result(pog.Returned(UsersWithRolesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use username <- decode.field(1, decode.string)
    use display_name <- decode.field(2, decode.string)
    use engineer_id <- decode.field(3, decode.optional(decode.int))
    use role <- decode.field(4, decode.optional(decode.string))
    decode.success(UsersWithRolesRow(
      id:,
      username:,
      display_name:,
      engineer_id:,
      role:,
    ))
  }

  "-- users_with_roles.sql — every account with the roles it holds as-of CURRENT_DATE (one
-- row per account/role; an account with no current role yields a single row with a NULL
-- role). The Access page groups rows into one entry per account. $1 has no params.
SELECT a.id, a.username, a.display_name, a.engineer_id, ur.role
  FROM account a
  LEFT JOIN user_role ur
    ON ur.account_id = a.id AND ur.held_during @> CURRENT_DATE
 ORDER BY a.display_name, a.id, ur.role;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}
