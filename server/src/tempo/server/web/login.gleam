//// Web: POST /api/login — authenticate an identity and issue a session (issue
//// #6). The body is `{actor}`: the identity the demo gate picked. In demo mode
//// (the default, ADR-035) any KNOWN identity authenticates without a password —
//// the gate gives the app the feel of named accountability; an UNKNOWN identity is
//// still refused, so the journal can never be stamped with junk. On success the
//// response carries a signed session cookie the operations handler reads back to
//// derive the actor server-side.
////
//// The demo password-less flow is behind the `TEMPO_AUTH_DEMO` flag (default on);
//// turning it off rejects every login until a real credential check is wired in —
//// the seam ADR-035 says real auth "slots in behind the same gate."

import gleam/dynamic/decode
import gleam/http
import gleam/json
import tempo/server/auth
import tempo/server/context.{type Context}
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// Handle POST /api/login: decode `{actor}`, authenticate it, and on success set
/// the signed session cookie and echo the principal's actor + role. A malformed
/// body is a 400; an unknown identity (or demo mode disabled) is a 401.
pub fn handle(req: wisp.Request, _ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_json(req)
  case decode.run(body, actor_decoder()) {
    Error(_) -> response.error_response(400, "invalid_body", "expected {actor}")
    Ok(actor) -> authenticate(req, actor)
  }
}

fn authenticate(req: wisp.Request, actor: String) -> wisp.Response {
  case demo_login_enabled(), auth.lookup(actor) {
    True, Ok(principal) ->
      response.json_response(encode_principal(principal))
      |> session.issue(req, principal)
    _, _ ->
      response.error_response(
        401,
        "unauthenticated",
        "no such identity, or demo login is disabled",
      )
  }
}

fn actor_decoder() -> decode.Decoder(String) {
  use actor <- decode.field("actor", decode.string)
  decode.success(actor)
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

/// Whether the password-less demo login is enabled. `TEMPO_AUTH_DEMO=off` disables
/// it (every login then 401s); any other value, or unset, leaves it on — so local
/// dev and the demo workspace authenticate by identity alone (ADR-035).
fn demo_login_enabled() -> Bool {
  context.env_string("TEMPO_AUTH_DEMO", "on") != "off"
}
