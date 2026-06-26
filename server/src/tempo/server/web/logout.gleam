//// Web: POST /api/logout — end the session by expiring the cookie. The session is
//// stateless (a signed cookie, no server record), so clearing that cookie IS the
//// logout: the next request carries no valid session and is unauthenticated. Returns
//// 200 with an empty JSON body; the client also drops its local actor and returns to
//// the login gate.

import gleam/http
import gleam/json
import tempo/server/context.{type Context}
import tempo/server/web/response
import tempo/server/web/session
import wisp

/// Handle POST /api/logout: clear the session cookie and return an empty `{}` body.
pub fn handle(req: wisp.Request, _ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  response.json_response(json.object([]))
  |> session.clear(req)
}
