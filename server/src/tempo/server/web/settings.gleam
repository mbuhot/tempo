//// Web: GET /api/settings?as_of= handler — the rate card, salaries, and leave
//// policy in force as of a date. Parse the as-of date, call the domain, encode the
//// result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks to
//// the domain `settings` module, which already speaks shared types.
////
//// A missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import shared/codecs
import tempo/server/context.{type Context}
import tempo/server/settings
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/settings?as_of=YYYY-MM-DD — the current rate card, salaries, and
/// leave policy as of the date.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case settings.read(ctx, as_of) {
        Ok(settings) -> response.json_response(codecs.encode_settings(settings))
        Error(_) -> wisp.internal_server_error()
      }
  }
}
