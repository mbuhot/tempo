//// Web: the session seam between the HTTP cookie and the domain `Principal`
//// (issue #6). Login issues a SIGNED cookie carrying the principal's session payload
//// (`auth.to_session`); the operations handler reads it back and re-derives the
//// `Principal`. A signed cookie cannot be tampered with by the client, so the
//// principal — and the journal `actor` derived from it — is unforgeable.
////
//// The cookie is built by hand rather than via `wisp.set_cookie` for ONE reason:
//// the "remember me" opt-in. wisp's helper always emits a `Max-Age`, but an
//// unchecked "remember me" must be a true SESSION cookie (no Max-Age/Expires) so the
//// browser drops it when it closes; a checked one is persistent (30 days). We sign
//// the value exactly as wisp's `Signed` mode does (`sign_message` with Sha512), so
//// `wisp.get_cookie(_, _, Signed)` still verifies it on the way back in. `clear`
//// expires the cookie on logout. The scheme rule mirrors wisp's so the cookie is not
//// `Secure` over `http://localhost` (or e2e login would never receive it).

import gleam/crypto
import gleam/http.{type Scheme, Http, Https}
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/result
import tempo/server/auth.{type Principal}
import wisp

/// The session cookie name. Signed (HMAC over the secret key base), so the client
/// can read but not forge it.
const cookie_name = "tempo_session"

/// Persistent-cookie lifetime when "remember me" is opted into: 30 days. Without the
/// opt-in the cookie carries no Max-Age and is a session cookie (cleared on browser
/// close).
const remember_max_age_seconds = 2_592_000

/// Issue the signed session cookie for a principal. `remember` chooses the cookie's
/// lifetime: opted in → a 30-day PERSISTENT cookie; not → a SESSION cookie (no
/// Max-Age) the browser drops when it closes. The value is the principal's session
/// payload signed so a client cannot rewrite it to impersonate another actor.
pub fn issue(
  response: wisp.Response,
  request: wisp.Request,
  principal: Principal,
  remember remember: Bool,
) -> wisp.Response {
  let payload = auth.to_session(principal)
  let value = wisp.sign_message(request, <<payload:utf8>>, crypto.Sha512)
  let max_age = case remember {
    True -> Some(remember_max_age_seconds)
    False -> None
  }
  set_session_cookie(response, request, value, max_age)
}

/// Expire the session cookie on logout: same name/attributes, empty value, Max-Age 0
/// (the cookie module also emits the epoch `Expires` so older clients clear it too).
pub fn clear(response: wisp.Response, request: wisp.Request) -> wisp.Response {
  set_session_cookie(response, request, "", Some(0))
}

/// Read and verify the signed session cookie, re-deriving the `Principal`. Returns
/// `Error(Nil)` when the cookie is absent, its signature does not verify (tampered
/// or signed under a different key), or the payload no longer maps to a valid
/// principal — every "not authenticated" case the handler turns into a 401.
pub fn principal(request: wisp.Request) -> Result(Principal, Nil) {
  use session <- result.try(wisp.get_cookie(request, cookie_name, wisp.Signed))
  auth.from_session(session)
}

/// Set the session cookie with the standard secure attributes (`HttpOnly`,
/// `SameSite=Lax`, `Path=/`, and `Secure` off localhost) and the given Max-Age:
/// `Some(n)` for a persistent/expiring cookie, `None` for a session cookie.
fn set_session_cookie(
  response: wisp.Response,
  request: wisp.Request,
  value: String,
  max_age: Option(Int),
) -> wisp.Response {
  let attributes =
    cookie.Attributes(..cookie.defaults(cookie_scheme(request)), max_age:)
  response.set_cookie(response, cookie_name, value, attributes)
}

/// The scheme the cookie's `Secure` flag is derived from, mirroring wisp's own
/// `set_cookie`: HTTPS everywhere except a plain-HTTP request to localhost (with no
/// `x-forwarded-proto`), so a dev/e2e server on `http://127.0.0.1` still gets the
/// cookie instead of the browser dropping a `Secure` cookie over HTTP.
fn cookie_scheme(req: wisp.Request) -> Scheme {
  case req.host {
    "localhost" | "127.0.0.1" | "[::1]" if req.scheme == Http ->
      case request.get_header(req, "x-forwarded-proto") {
        Ok(_) -> Https
        Error(_) -> Http
      }
    _ -> Https
  }
}
