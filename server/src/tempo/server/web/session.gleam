//// Web: the session seam between the HTTP cookie and the domain `Principal` (issue #6).
//// The signed cookie carries ONLY the authenticated account id — roles and permissions
//// are temporal, so they are resolved from the database as-of each request (never baked
//// into the cookie), and a revoked role takes effect immediately. Login issues the
//// cookie; the operations handler and the read guard read it back and `access.resolve`
//// the full `Principal`. A signed cookie cannot be forged, so the account id — and the
//// permissions resolved from it — are trustworthy.
////
//// The cookie is built by hand (not `wisp.set_cookie`) for the "remember me" opt-in:
//// unchecked is a true SESSION cookie (no Max-Age, dropped on browser close), checked is
//// persistent (30 days). The value is signed exactly as wisp's `Signed` mode, so
//// `wisp.get_cookie(_, _, Signed)` verifies it. `clear` expires the cookie on logout.

import gleam/crypto
import gleam/http.{type Scheme, Http, Https}
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import tempo/server/access/view as access
import tempo/server/auth.{type Principal}
import tempo/server/context.{type Context}
import wisp

/// The session cookie name. Signed (HMAC over the secret key base), so the client can
/// read but not forge it.
const cookie_name = "tempo_session"

/// Persistent-cookie lifetime when "remember me" is opted into: 30 days. Without the
/// opt-in the cookie carries no Max-Age and is a session cookie (cleared on browser
/// close).
const remember_max_age_seconds = 2_592_000

/// Issue the signed session cookie for an authenticated account. `remember` chooses the
/// lifetime: opted in → a 30-day PERSISTENT cookie; not → a SESSION cookie. The value is
/// the account id, signed so a client cannot rewrite it to impersonate another account.
pub fn issue(
  response: wisp.Response,
  request: wisp.Request,
  account_id: Int,
  remember remember: Bool,
) -> wisp.Response {
  let value =
    wisp.sign_message(
      request,
      <<int.to_string(account_id):utf8>>,
      crypto.Sha512,
    )
  let max_age = case remember {
    True -> Some(remember_max_age_seconds)
    False -> None
  }
  set_session_cookie(response, request, value, max_age)
}

/// Expire the session cookie on logout: same name/attributes, empty value, Max-Age 0.
pub fn clear(response: wisp.Response, request: wisp.Request) -> wisp.Response {
  set_session_cookie(response, request, "", Some(0))
}

/// Read and verify the signed session cookie, then resolve the full `Principal` (display
/// name, linked engineer, and effective permissions as-of today) from the database.
/// Returns `Error(Nil)` when the cookie is absent/invalid or the account no longer
/// exists — every "not authenticated" case the handler turns into a 401.
pub fn principal(
  request: wisp.Request,
  context: Context,
) -> Result(Principal, Nil) {
  use raw <- result.try(wisp.get_cookie(request, cookie_name, wisp.Signed))
  use account_id <- result.try(int.parse(raw))
  access.resolve(context, account_id)
}

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

/// The scheme the cookie's `Secure` flag derives from, mirroring wisp's own
/// `set_cookie`: HTTPS everywhere except a plain-HTTP request to localhost, so a dev/e2e
/// server on `http://127.0.0.1` still receives the cookie.
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
