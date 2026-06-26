//// Web: the read-side authorization guard — the GET-endpoint analogue of the write gate
//// in `command.dispatch`. `authenticated` reads the request `Principal` the router's
//// authentication middleware already resolved into `Context.principal` (401 when it is
//// `None`) and hands it to the handler; `require` additionally checks a permission (403
//// otherwise). Pure — no cookie, no database: the middleware did that once up front, so
//// each read handler stays free of session/permission plumbing and the router wraps a
//// route with only the permission it needs.

import gleam/option.{None, Some}
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/web/response
import wisp

/// Hand the request principal to the handler, or 401 when there is none. Use for
/// endpoints whose own logic decides access (e.g. an ownership read that allows the
/// engineer their own record).
pub fn authenticated(
  context: Context,
  next: fn(Principal) -> wisp.Response,
) -> wisp.Response {
  case context.principal {
    Some(principal) -> next(principal)
    None ->
      response.error_response(401, "unauthenticated", "sign in to continue")
  }
}

/// Require an authenticated principal (401) holding `permission` (403) before running the
/// handler.
pub fn require(
  context: Context,
  permission: String,
  next: fn(Principal) -> wisp.Response,
) -> wisp.Response {
  use principal <- authenticated(context)
  case auth.can(principal, permission) {
    True -> next(principal)
    False ->
      response.error_response(
        403,
        "forbidden",
        "you do not have permission to view this",
      )
  }
}
