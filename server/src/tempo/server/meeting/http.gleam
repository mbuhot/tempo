//// Web: GET /api/meetings?as_of= — the upcoming-scheduled-meetings listing, and
//// GET /api/meetings/find-a-time — the cross-timezone slot finder. Parse the query,
//// call the domain, encode the result. Imports `wisp` (it owns the HTTP shape) but
//// never `sql` — it talks to the domain `meeting` view, which already speaks shared
//// types.

import gleam/http
import gleam/json
import gleam/option
import gleam/result
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

/// Handle GET /api/meetings/find-a-time?from=&to=&tz=&duration=&required=&optional=&exclude=
/// — every window inside `[from, to]` (dates in `tz`, the viewer's zone) at least
/// `duration` minutes long during which every `required` engineer (comma-separated
/// ids) is free; `optional` (comma-separated ids) ride along with their offsets but
/// never narrow the windows; `exclude` (a meeting id, default none) vacates that
/// meeting's own booking, so rescheduling it can offer its current slot back. A
/// missing/malformed query parameter or an unrecognised `tz` is a 400; a database
/// failure is a 500.
pub fn handle_find_time(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let params = {
    use from <- result.try(request.date_from_query(req, "from"))
    use to <- result.try(request.date_from_query(req, "to"))
    use timezone <- result.try(
      request.optional_string_from_query(req, "tz")
      |> option.to_result("missing query parameter 'tz'"),
    )
    use duration_minutes <- result.try(positive_duration(req))
    use required <- result.try(request.ids_from_query(req, "required"))
    use optional <- result.try(request.optional_ids_from_query(req, "optional"))
    use exclude <- result.map(request.optional_int_from_query(req, "exclude"))
    #(
      from,
      to,
      timezone,
      duration_minutes,
      required,
      optional,
      option.unwrap(exclude, 0),
    )
  }
  case params {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(from, to, timezone, duration_minutes, required, optional, exclude)) ->
      case
        view.find_time(
          ctx,
          from,
          to,
          timezone,
          duration_minutes,
          required,
          optional,
          exclude,
        )
      {
        Ok(slots) ->
          response.json_response(json.array(
            slots,
            meeting_view.encode_candidate_slot,
          ))
        Error(view.UnknownTimezone) ->
          wisp.bad_request("unknown timezone '" <> timezone <> "'")
        Error(view.FindTimeQueryFailed(error)) ->
          response.db_error_response(error)
      }
  }
}

fn positive_duration(req: wisp.Request) -> Result(Int, String) {
  use minutes <- result.try(request.int_from_query(req, "duration"))
  case minutes > 0 {
    True -> Ok(minutes)
    False -> Error("'duration' must be a positive number of minutes")
  }
}
