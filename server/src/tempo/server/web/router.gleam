//// Web: Wisp request router. Routes HTTP requests to the board/timesheet/
//// operations/events handlers and serves static assets; it also exposes the
//// shared JSON-response helpers the handlers reuse. This module (the whole
//// `web/` layer) owns HTTP and never imports `sql` — the handlers reach the
//// database only through the domain.
////
//// Thin dispatch (task spec Notes): each route delegates to a handler that calls
//// the domain, maps the result to shared types, and encodes JSON. Everything else
//// is served from `priv/static` (the compiled Lustre bundle + index.html) so the
//// SPA and its API share one origin.
////
//// The shared `json_response`/`error_response` helpers live in `web/response` (a
//// leaf module both this router and the handlers import). Because the router must
//// import the handlers to dispatch to them, the handlers cannot import the router
//// back without a cycle, so the helpers sit in that leaf rather than here.

import gleam/erlang/application
import gleam/option
import gleam/result
import simplifile
import tempo/server/context.{type Context}
import tempo/server/web/board
import tempo/server/web/events
import tempo/server/web/invoices
import tempo/server/web/operations
import tempo/server/web/payroll
import tempo/server/web/pnl
import tempo/server/web/roster
import tempo/server/web/timesheet
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
    ["api", "timesheet"] -> timesheet.handle_read(request, context)
    ["api", "operations"] -> operations.handle(request, context)
    ["api", "events"] -> events.handle(request, context)
    ["api", "invoices"] -> invoices.handle_list(request, context)
    ["api", "invoices", id] -> invoices.handle_detail(request, context, id)
    ["api", "payroll"] -> payroll.handle(request, context)
    ["api", "pnl"] -> pnl.handle(request, context)
    ["api", "roster"] -> roster.handle(request, context)
    [] -> serve_index()
    _ -> wisp.not_found()
  }
}

// --- static assets ----------------------------------------------------------

/// Serve the SPA shell `priv/static/index.html` at the application root (a 404 if
/// the file is absent).
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
