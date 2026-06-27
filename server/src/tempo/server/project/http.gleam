//// Web: the project read handlers — GET /api/projects?as_of= (list) and
//// GET /api/projects/:id?as_of= (detail). Parse the request, call the domain, encode
//// the result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks
//// to the domain `project_detail` module, which already speaks shared types.
////
//// Both reads take an `as_of` date: the list shows each project's active flag and
//// team size as of the date, the detail its run active flag, team and invoices as
//// of the date. A missing/malformed `as_of` is a 400; an unknown project id is a
//// 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/option
import gleam/result
import gleam/time/calendar.{type Date}
import shared/project/view as project_view
import shared/table/query.{Applied}
import shared/table/response as table_response
import tempo/server/context.{type Context}
import tempo/server/project/table as project_table
import tempo/server/project/view as project_detail
import tempo/server/web/cursor
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/projects?as_of=YYYY-MM-DD&cursor=&limit= — one keyset page of the
/// projects directory (issue #12), each project with its client, budget, target,
/// team size, and active flag, plus the `next_cursor` for the following page.
/// `cursor` is the opaque token from a prior page (absent ⇒ first page); `limit`
/// defaults and is clamped. A malformed `cursor`/`limit` is a 400.
pub fn handle_list(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let parsed = {
    use as_of <- result.try(request.date_from_query(req, "as_of"))
    use after <- result.try(name_id_cursor(req))
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
      case project_detail.list(ctx, as_of, after, limit) {
        Ok(list) ->
          response.json_response(project_view.encode_project_list(list))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Handle GET /api/projects/table?as_of=&filter.*=&sort=&page_size=&cursor= — the
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
          project_table.filter_schema(),
          context.default_page_limit,
        )
      let clamped =
        Applied(..applied, page_size: context.clamp_limit(applied.page_size))
      case project_table.project_table(ctx, as_of, clamped) {
        Ok(table) ->
          response.json_response(table_response.encode_response(table))
        Error(error) -> response.db_error_response(error)
      }
    }
  }
}

/// Parse the optional `cursor` param into the projects keyset bound: absent ⇒ the
/// first-page sentinel, present-and-valid ⇒ its `(title, project_id)` bound,
/// present-but-malformed ⇒ `Error(detail)` for a 400.
fn name_id_cursor(req: wisp.Request) -> Result(cursor.NameIdBound, String) {
  case request.optional_string_from_query(req, "cursor") {
    option.None -> Ok(cursor.name_id_start())
    option.Some(token) ->
      cursor.decode_name_id(token)
      |> result.replace_error("invalid cursor '" <> token <> "'")
  }
}

/// Handle GET /api/projects/:id?as_of=YYYY-MM-DD — one project's profile, plan,
/// client, run period, team, and invoices as of the date. A non-integer id is a
/// 400, an unknown id a 404.
pub fn handle_detail(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid project id '" <> id_segment <> "'")
    Ok(project_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) -> detail_response(ctx, project_id, as_of)
      }
  }
}

fn detail_response(
  ctx: Context,
  project_id: Int,
  as_of: Date,
) -> wisp.Response {
  case project_detail.detail(ctx, project_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(project_view.encode_project_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
