//// Web: GET /api/engineers/:id/availability?as_of= and GET /api/holidays?as_of=
//// handlers — one engineer's as-of weekly hours/focus blocks/holidays, and the
//// full upcoming holidays listing. Parse the path/query, call the domain, encode
//// the result.

import gleam/http
import gleam/int
import gleam/json
import shared/availability/view as availability_view
import tempo/server/availability/view
import tempo/server/context.{type Context}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/engineers/:id/availability?as_of=YYYY-MM-DD — one engineer's
/// as-of weekly hours grid, upcoming focus blocks, and upcoming holidays.
pub fn handle_availability(
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
          case view.availability(ctx, engineer_id, as_of) {
            Ok(record) ->
              response.json_response(
                availability_view.encode_availability_record(record),
              )
            Error(error) -> response.db_error_response(error)
          }
      }
  }
}

/// Handle GET /api/holidays?as_of=YYYY-MM-DD — every upcoming holiday across all
/// seeded regions, with region names.
pub fn handle_holidays(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) ->
      case view.holidays(ctx, as_of) {
        Ok(records) ->
          response.json_response(json.array(
            records,
            availability_view.encode_holiday_listing,
          ))
        Error(error) -> response.db_error_response(error)
      }
  }
}
