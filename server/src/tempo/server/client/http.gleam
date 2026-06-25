//// Web: the client read handlers — GET /api/clients?as_of= (list) and
//// GET /api/clients/:id?as_of= (detail). Parse the request, call the domain, encode
//// the result. Imports `wisp` (it owns the HTTP shape) but never `sql` — it talks
//// to the domain `client_detail` module, which already speaks shared types.
////
//// Both reads take an `as_of` date: the list shows each client's active flag as of
//// the date, the detail computes its contract/project active flags as of the date
//// (the profile name is durable). A missing/malformed `as_of` is a 400; an unknown
//// client id is a 404; a database failure is a 500.

import gleam/http
import gleam/int
import gleam/option
import gleam/result
import gleam/time/calendar.{type Date}
import shared/client/view as client_view
import tempo/server/client/view as client_detail
import tempo/server/context.{type Context}
import tempo/server/web/cursor
import tempo/server/web/request
import tempo/server/web/response
import wisp

/// Handle GET /api/clients?as_of=YYYY-MM-DD&cursor=&limit= — one keyset page of the
/// clients directory (issue #12), each client with its `since`, project count, and
/// active flag, plus the `next_cursor` for the following page. `cursor` is the
/// opaque token from a prior page (absent ⇒ first page); `limit` defaults and is
/// clamped. A malformed `cursor`/`limit` is a 400.
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
      case client_detail.list(ctx, as_of, after, limit) {
        Ok(list) -> response.json_response(client_view.encode_client_list(list))
        Error(error) -> response.db_error_response(error)
      }
  }
}

/// Parse the optional `cursor` param into the clients keyset bound: absent ⇒ the
/// first-page sentinel, present-and-valid ⇒ its `(name, client_id)` bound,
/// present-but-malformed ⇒ `Error(detail)` for a 400.
fn name_id_cursor(req: wisp.Request) -> Result(cursor.NameIdBound, String) {
  case request.optional_string_from_query(req, "cursor") {
    option.None -> Ok(cursor.name_id_start())
    option.Some(token) ->
      cursor.decode_name_id(token)
      |> result.replace_error("invalid cursor '" <> token <> "'")
  }
}

/// Handle GET /api/clients/:id?as_of=YYYY-MM-DD — one client's profile, `since`,
/// contracts, and projects (active flags as of the date). A non-integer id is a
/// 400, an unknown id a 404.
pub fn handle_detail(
  req: wisp.Request,
  ctx: Context,
  id_segment: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  case int.parse(id_segment) {
    Error(Nil) -> wisp.bad_request("invalid client id '" <> id_segment <> "'")
    Ok(client_id) ->
      case request.date_from_query(req, "as_of") {
        Error(detail) -> wisp.bad_request(detail)
        Ok(as_of) -> detail_response(ctx, client_id, as_of)
      }
  }
}

fn detail_response(ctx: Context, client_id: Int, as_of: Date) -> wisp.Response {
  case client_detail.detail(ctx, client_id, as_of) {
    Ok(Ok(detail)) ->
      response.json_response(client_view.encode_client_detail(detail))
    Ok(Error(Nil)) -> wisp.not_found()
    Error(error) -> response.db_error_response(error)
  }
}
