//// Web: GET /api/events handler. Parses the optional filter params, calls the
//// domain, encodes the result. Imports `wisp` (it owns the HTTP shape) but never
//// `sql` — it talks to the domain `event` module, which already speaks shared types.

import gleam/http
import gleam/option
import gleam/result
import shared/command.{EventPage}
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/event
import tempo/server/event/table as event_table
import tempo/server/web/cursor.{type IdBound}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/events?from=&to=&operation=&actor= — the provenance journal
/// newest-first over a half-open `[from, to)` window with optional operation/actor
/// filters. This is SYSTEM time (`occurred_at`), independent of the valid-time
/// rail; all four params are optional, so no params returns the whole journal.
///
/// Thin handler: parse the optional params, run the domain query, encode each
/// `Event` to a JSON array. A present-but-malformed date param is a 400; missing
/// params are NOT an error; a database failure is a 500.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let parsed = {
    use from <- result.try(request.optional_date_from_query(req, "from"))
    use to <- result.try(request.optional_date_from_query(req, "to"))
    use after <- result.try(events_cursor(req))
    use limit <- result.map(request.optional_int_from_query(req, "limit"))
    let operation = request.optional_string_from_query(req, "operation")
    let actor = request.optional_string_from_query(req, "actor")
    #(
      from,
      to,
      operation,
      actor,
      after,
      context.clamp_limit(option.unwrap(limit, context.default_page_limit)),
    )
  }
  case parsed {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(from, to, operation, actor, after, limit)) ->
      case event.list(ctx, from, to, operation, actor, after, limit) {
        Ok(#(events, next_cursor)) ->
          response.json_response(
            command.encode_event_page(EventPage(events:, next_cursor:)),
          )
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/events/table?filter.*=&page_size=&cursor= — the Activity journal
/// as the generic data-table read: the schema the client renders from (three columns
/// plus the three schema-level filters) and one filtered, paged slice of rows
/// newest-first, each carrying its pretty-printed JSON payload as a detail panel.
/// Filters/page are parsed from the query params against the table's filter schema;
/// `page_size` is clamped to the server bound. The journal is system-time, so this
/// read takes no `as_of`. A database failure is a 500.
pub fn handle_table(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let applied =
    query.from_params(
      wisp.get_query(req),
      event_table.filter_schema(),
      context.default_page_limit,
    )
  let clamped =
    Applied(..applied, page_size: context.clamp_limit(applied.page_size))
  case event_table.events_table(ctx, clamped) {
    Ok(table) -> response.json_response(table_response.encode_response(table))
    Error(error) -> response.db_error_response(error)
  }
}

/// Parse the optional `cursor` param into the journal's id upper bound: absent ⇒
/// the first-page sentinel (above every id), present-and-valid ⇒ its id bound,
/// present-but-malformed ⇒ `Error(detail)` for a 400.
fn events_cursor(req: wisp.Request) -> Result(IdBound, String) {
  case request.optional_string_from_query(req, "cursor") {
    option.None -> Ok(cursor.id_desc_start())
    option.Some(token) ->
      cursor.decode_id(token)
      |> result.replace_error("invalid cursor '" <> token <> "'")
  }
}
