//// Web: GET /api/access — the Access management page snapshot (the role->permission
//// matrix and every account's current roles). The router gates this route on
//// `roles.manage`, so only an Owner reaches here. Encodes the shared `AccessSnapshot`.

import gleam/http
import shared/access/view as access_view
import tempo/server/access/view as access
import tempo/server/context.{type Context}
import tempo/server/web/response
import wisp

/// Handle GET /api/access: assemble the snapshot and encode it, or map a storage fault
/// to a 5xx.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case access.snapshot(ctx) {
    Ok(snapshot) ->
      response.json_response(access_view.encode_access_snapshot(snapshot))
    Error(error) -> response.db_error_response(error)
  }
}
