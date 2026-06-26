//// Web: GET /api/me — the authenticated identity and its effective permissions,
//// resolved as-of now (the SAME `access.resolve` the gate uses), so the client reads
//// exactly what the server will enforce. The router wraps this in `guard.authenticated`
//// (401 when there is no valid session), which hands in the resolved `Principal`; this
//// just encodes it. The client calls it on boot to restore a session from the cookie
//// and to refresh permissions after a change.

import gleam/http
import tempo/server/auth.{type Principal}
import tempo/server/web/identity
import tempo/server/web/response
import wisp

/// Handle GET /api/me: encode the already-resolved principal as `{actor, engineer_id,
/// permissions}`.
pub fn handle(req: wisp.Request, principal: Principal) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  response.json_response(identity.encode(principal))
}
