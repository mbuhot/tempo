//// Web: GET /api/locations?as_of= and GET /api/engineers/:id/location handlers — the
//// as-of engineer-location listing and one engineer's location history. Parse the
//// query/path, call the domain, encode the result. Imports `wisp` (it owns the HTTP
//// shape) but never `sql` — it talks to the domain `location` view, which already
//// speaks shared types.

import gleam/http
import gleam/int
import gleam/json
import shared/location/view as location_view
import tempo/server/context.{type Context}
import tempo/server/location/view
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/locations?as_of=YYYY-MM-DD — every engineer and their location
/// as-of the date.
pub fn handle_listing(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case view.listing(ctx, as_of) {
        Ok(entries) ->
          response.json_response(json.array(
            entries,
            location_view.encode_engineer_location,
          ))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/engineers/:id/location?as_of= — one engineer's full location
/// history, each span's UTC offset computed as-of the date.
pub fn handle_history(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid engineer id '" <> id_segment <> "'")
    Ok(engineer_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) ->
          case view.history(ctx, engineer_id, as_of) {
            Ok(records) ->
              response.json_response(json.array(
                records,
                location_view.encode_location_record,
              ))
            Error(error) -> response.db_error_response(error)
          }
      }
  }
}
