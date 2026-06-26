//// Web: POST /api/login — verify a username/password and issue a session (issue #6).
//// The body is `{username, password, remember_me?}`. Credentials are checked against the
//// `account` table (PBKDF2-hashed); on success the response carries a signed session
//// cookie holding the account id — persistent when `remember_me`, a session cookie
//// otherwise — and echoes the authenticated `actor`, the linked `engineer_id`, and the
//// resolved `permissions` (so the client can gate its UI). Roles/permissions are NOT in
//// the cookie; they are resolved per request from the temporal access maps.
////
//// Failures are UNIFORM: an unknown username and a wrong password both return the same
//// 401 with no detail, so login leaks no oracle for which accounts exist. Only a storage
//// fault surfaces as a 5xx.

import gleam/dynamic/decode
import gleam/http
import tempo/server/access/view as access
import tempo/server/account/view as account
import tempo/server/context.{type Context}
import tempo/server/web/identity
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// The login request body. `remember_me` defaults to false when omitted — the safe
/// default (a session cookie rather than a 30-day persistent one).
pub type Credentials {
  Credentials(username: String, password: String, remember_me: Bool)
}

/// Handle POST /api/login: decode the credentials, authenticate them, resolve the
/// principal, set the signed session cookie (honouring `remember_me`), and echo the
/// identity + permissions. A malformed body is 400; bad credentials are 401; a storage
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
    Ok(found) ->
      case access.resolve(ctx, found.id) {
        Ok(principal) ->
          response.json_response(identity.encode(principal))
          |> session.issue(req, found.id, remember: credentials.remember_me)
        Error(Nil) -> unauthenticated()
      }
    Error(account.StoreError(error)) -> response.db_error_response(error)
    _ -> unauthenticated()
  }
}

fn unauthenticated() -> wisp.Response {
  response.error_response(
    401,
    "unauthenticated",
    "invalid username or password",
  )
}

fn credentials_decoder() -> decode.Decoder(Credentials) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  use remember_me <- decode.optional_field("remember_me", False, decode.bool)
  decode.success(Credentials(username:, password:, remember_me:))
}
