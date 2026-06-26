//// Web: the read-side authorization guard — the GET-endpoint analogue of the write gate
//// in `command.dispatch`. `authenticated` resolves the request `Principal` (401 if the
//// session is absent/invalid) and hands it to the handler; `require` additionally checks
//// a permission (403 otherwise). Keeps each read handler free of session/permission
//// plumbing — the router wraps a route with the permission it needs.

import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// Resolve the request principal or 401. Use for endpoints whose own logic decides
/// access (e.g. an ownership read that allows the engineer their own record).
pub fn authenticated(
  request: wisp.Request,
  context: Context,
  next: fn(Principal) -> wisp.Response,
) -> wisp.Response {
  case session.principal(request, context) {
    Ok(principal) -> next(principal)
    Error(Nil) ->
      response.error_response(401, "unauthenticated", "sign in to continue")
  }
}

/// Resolve the principal (401) and require `permission` (403) before running the handler.
pub fn require(
  request: wisp.Request,
  context: Context,
  permission: String,
  next: fn(Principal) -> wisp.Response,
) -> wisp.Response {
  use principal <- authenticated(request, context)
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
