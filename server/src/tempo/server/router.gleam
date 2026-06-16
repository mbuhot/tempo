//// Wisp request router dispatching to board/timesheet handlers.
////
//// Thin dispatch (task spec Notes): each route delegates to a handler that
//// queries, maps Squirrel rows to shared types, and encodes JSON. Everything
//// else is served from `priv/static` (the compiled Lustre bundle + index.html,
//// which arrive in P4) so the SPA and its API share one origin.

import gleam/erlang/application
import gleam/http
import gleam/option
import gleam/result
import simplifile
import tempo/server/board
import tempo/server/context.{type Context}
import tempo/server/timesheet
import wisp

/// Top-level request handler: wrap every request in the standard Wisp
/// middleware, then route by path. `/api/*` hits the JSON handlers; anything
/// else falls through to static file serving from `priv/static`.
pub fn handle_request(
  request: wisp.Request,
  context: Context,
) -> wisp.Response {
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use <- wisp.serve_static(request, under: "/static", from: static_directory())

  case wisp.path_segments(request) {
    ["api", "board"] -> board.handle(request, context)
    ["api", "timesheet"] -> timesheet_route(request, context)
    [] -> serve_index()
    _ -> wisp.not_found()
  }
}

/// `/api/timesheet` is read (GET) or write (POST); the handlers each enforce
/// their own method, returning 405 for the wrong verb.
fn timesheet_route(request: wisp.Request, context: Context) -> wisp.Response {
  case request.method {
    http.Get -> timesheet.handle_read(request, context)
    _ -> timesheet.handle_write(request, context)
  }
}

/// Serve the SPA shell `priv/static/index.html` at the application root (P4
/// delivers the bundle; until then this is a 404 if the file is absent).
fn serve_index() -> wisp.Response {
  let index = static_directory() <> "/index.html"
  case simplifile.is_file(index) {
    Ok(True) ->
      wisp.ok()
      |> wisp.set_body(wisp.File(path: index, offset: 0, limit: option.None))
      |> wisp.set_header("content-type", "text/html; charset=utf-8")
    _ -> wisp.not_found()
  }
}

/// Absolute path to `priv/static`, resolved from the OTP application's priv dir
/// at runtime. Falls back to a relative path if the app is not yet started.
fn static_directory() -> String {
  application.priv_directory("tempo")
  |> result.unwrap("priv")
  |> string_append_static
}

fn string_append_static(priv: String) -> String {
  priv <> "/static"
}
