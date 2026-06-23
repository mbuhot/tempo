//// Web: the session seam between the HTTP cookie and the domain `Principal`
//// (issue #6). The login endpoint issues a SIGNED cookie carrying the principal's
//// session payload (`auth.to_session`); the operations handler reads it back and
//// re-derives the `Principal`. A signed cookie cannot be tampered with by the
//// client, so the principal — and the journal `actor` derived from it — is
//// unforgeable.
////
//// This is the only place that knows the cookie name and the wisp cookie API; the
//// domain `auth` module owns the principal<->string mapping, and this module wraps
//// it in `wisp.set_cookie`/`wisp.get_cookie` with `Signed` security.

import gleam/result
import tempo/server/auth.{type Principal}
import wisp

/// The session cookie name. Signed (HMAC over the secret key base), so the client
/// can read but not forge it.
const cookie_name = "tempo_session"

/// How long a session cookie lives (24h), matching the demo's single-day workshop
/// use; long enough to not surprise, short enough to expire.
const max_age_seconds = 86_400

/// Set the signed session cookie for a principal on a response. The value is the
/// principal's session payload (`auth.to_session`), signed so a client cannot
/// rewrite it to impersonate another actor.
pub fn issue(
  response: wisp.Response,
  request: wisp.Request,
  principal: Principal,
) -> wisp.Response {
  wisp.set_cookie(
    response,
    request,
    cookie_name,
    auth.to_session(principal),
    wisp.Signed,
    max_age_seconds,
  )
}

/// Read and verify the signed session cookie, re-deriving the `Principal`. Returns
/// `Error(Nil)` when the cookie is absent, its signature does not verify (tampered
/// or signed under a different key), or the payload no longer maps to a known
/// principal — every "not authenticated" case the handler turns into a 401.
pub fn principal(request: wisp.Request) -> Result(Principal, Nil) {
  use session <- result.try(wisp.get_cookie(request, cookie_name, wisp.Signed))
  auth.from_session(session)
}
