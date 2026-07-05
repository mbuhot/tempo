//// Web: GET /api/meetings?as_of= — the upcoming-scheduled-meetings listing. Parse the
//// query, call the domain, encode the result. Imports `wisp` (it owns the HTTP shape)
//// but never `sql` — it talks to the domain `meeting` view, which already speaks
//// shared types.

import gleam/http
import gleam/json
import shared/meeting/view as meeting_view
import tempo/server/context.{type Context}
import tempo/server/meeting/view
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/meetings?as_of=YYYY-MM-DD — every scheduled meeting ending on/after
/// the date, earliest first, each with its attendees and their local UTC offsets.
pub fn handle_listing(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case view.upcoming(ctx, as_of) {
        Ok(records) ->
          response.json_response(json.array(
            records,
            meeting_view.encode_meeting_record,
          ))
        Error(error) -> response.db_error_response(error)
      }
  }
}
