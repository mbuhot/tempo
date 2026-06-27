//// Web: GET /api/people?as_of= handler — the people roster for a date. Parse the
//// as-of date, call the domain, encode the result. Imports `wisp` (it owns the HTTP
//// shape) but never `sql` — it talks to the domain `people` module, which already
//// speaks shared types.
////
//// A missing/malformed `as_of` is a 400; a database failure is a 500.

import gleam/http
import gleam/option
import gleam/result
import shared/people/view as people_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/people/table as people_table
import tempo/server/people/view as people
import tempo/server/web/cursor.{type NameIdBound}
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/people?as_of=YYYY-MM-DD&cursor=&limit= — one keyset page of the
/// people roster (issue #12), each employed engineer's row (level, status,
/// allocation, annual balance, day rate) plus the `next_cursor` for the following
/// page. `cursor` is the opaque token from a prior page (absent ⇒ first page);
/// `limit` defaults to the server default and is clamped. A malformed
/// `cursor`/`limit` is a 400.
pub fn handle(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let parsed = {
    use as_of <- result.try(request.date_from_query(req, "as_of"))
    use after <- result.try(people_cursor(req))
    use limit <- result.map(request.optional_int_from_query(req, "limit"))
    #(
      as_of,
      after,
      context.clamp_limit(option.unwrap(limit, context.default_page_limit)),
    )
  }
  case parsed {
    Error(detail) -> wisp.bad_request(detail)
    Ok(#(as_of, after, limit)) ->
      case people.roster(ctx, as_of, after, limit) {
        Ok(list) -> response.json_response(people_view.encode_people_list(list))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/people/table?as_of=&filter.*=&sort=&page_size=&cursor= — the
/// generic data-table read: the schema the client renders from plus one filtered,
/// sorted, paged slice of rows. Filters/sort/page are parsed from the query params
/// against the table's filter schema; `page_size` is clamped to the server bound. A
/// missing/malformed `as_of` is a 400; a database failure is a 500.
pub fn handle_table(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case request.date_from_query(req, "as_of") {
    Error(detail) -> wisp.bad_request(detail)
    Ok(as_of) -> {
      let applied =
        query.from_params(
          wisp.get_query(req),
          people_table.filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case people_table.people_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}

/// Parse the optional `cursor` param into the people keyset bound: absent ⇒ the
/// first-page sentinel, present-and-valid ⇒ its `(name, engineer_id)` bound,
/// present-but-malformed ⇒ `Error(detail)` for a 400.
fn people_cursor(req: wisp.Request) -> Result(NameIdBound, String) {
  case request.optional_string_from_query(req, "cursor") {
    option.None -> Ok(cursor.name_id_start())
    option.Some(token) ->
      cursor.decode_name_id(token)
      |> result.replace_error("invalid cursor '" <> token <> "'")
  }
}
