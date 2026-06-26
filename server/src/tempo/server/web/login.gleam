//// Web: POST /api/login — verify a username/password and issue a session (issue
//// #6). The body is `{username, password, remember_me?}`. Credentials are checked
//// against the `account` table (PBKDF2-hashed); on success the response carries a
//// signed session cookie — persistent when `remember_me` is true, a session cookie
//// otherwise — that the operations handler reads back to derive the actor
//// server-side.
////
//// Failures are UNIFORM: an unknown username, a wrong password, and a corrupt
//// account all return the same 401 with no detail, so login leaks no oracle for
//// which accounts exist. Only a storage fault surfaces as a 5xx.

import gleam/dynamic/decode
import gleam/http
import gleam/json
import tempo/server/account/view as account
import tempo/server/auth
import tempo/server/context.{type Context}
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// The login request body. `remember_me` defaults to false when omitted — the
/// safe default (a session cookie rather than a 30-day persistent one).
pub type Credentials {
  Credentials(username: String, password: String, remember_me: Bool)
}

/// Handle POST /api/login: decode the credentials, authenticate them, and on success
/// set the signed session cookie (honouring `remember_me`) and echo the principal's
/// actor + role. A malformed body is a 400; bad credentials are a 401; a storage
/// fault is a 5xx.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)
  case decode.run(body, credentials_decoder()) {
    Error(_) ->
      response.error_response(
        400,
        "invalid_body",
        "expected {username, password}",
      )
    Ok(credentials) -> authenticate(req, ctx, credentials)
  }
}

fn authenticate(
  req: wisp.Request,
  ctx: Context,
  credentials: Credentials,
) -> wisp.Response {
  case
    account.authenticate(ctx.db, credentials.username, credentials.password)
  {
    Ok(principal) ->
      response.json_response(encode_principal(principal))
      |> session.issue(req, principal, remember: credentials.remember_me)
    Error(account.StoreError(error)) -> response.db_error_response(error)
    _ ->
      response.error_response(
        401,
        "unauthenticated",
        "invalid username or password",
      )
  }
}

fn credentials_decoder() -> decode.Decoder(Credentials) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  use remember_me <- decode.optional_field("remember_me", False, decode.bool)
  decode.success(Credentials(username:, password:, remember_me:))
}

fn encode_principal(principal: auth.Principal) -> json.Json {
  json.object([
    #("actor", json.string(principal.actor)),
    #("role", json.string(role_label(principal.role))),
  ])
}

fn role_label(role: auth.Role) -> String {
  case role {
    auth.Admin -> "admin"
    auth.Ops -> "ops"
    auth.Engineer -> "engineer"
  }
}
