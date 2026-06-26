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
import tempo/server/board/http as board
import tempo/server/client/http as clients
import tempo/server/context.{type Context}
import tempo/server/engineer/http as engineers
import tempo/server/forecast/http as forecast
import tempo/server/invoice/http as invoices
import tempo/server/payroll/http as payroll
import tempo/server/people/http as people
import tempo/server/pnl/http as pnl
import tempo/server/project/http as projects
import tempo/server/roster/http as roster
import tempo/server/settings/http as settings
import tempo/server/timesheet/http as timesheet
import tempo/server/web/events
import tempo/server/web/login
import tempo/server/web/logout
import tempo/server/web/operations
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
  use <- serve_static_no_cache(request)

  case wisp.path_segments(request) {
    ["api", "login"] -> login.handle(request, context)
    ["api", "logout"] -> logout.handle(request, context)
    ["api", "board"] -> board.handle(request, context)
    ["api", "timesheet"] -> timesheet.handle_read(request, context)
    ["api", "operations"] -> operations.handle(request, context)
    ["api", "events"] -> events.handle(request, context)
    ["api", "invoices"] -> invoices.handle_list(request, context)
    ["api", "invoices", id] -> invoices.handle_detail(request, context, id)
    ["api", "payroll"] -> payroll.handle(request, context)
    ["api", "pnl"] -> pnl.handle(request, context)
    ["api", "forecast"] -> forecast.handle(request, context)
    ["api", "roster"] -> roster.handle(request, context)
    ["api", "people"] -> people.handle(request, context)
    ["api", "engineers", id] -> engineers.handle_detail(request, context, id)
    ["api", "clients"] -> clients.handle_list(request, context)
    ["api", "clients", id] -> clients.handle_detail(request, context, id)
    ["api", "projects"] -> projects.handle_list(request, context)
    ["api", "projects", id] -> projects.handle_detail(request, context, id)
    ["api", "settings"] -> settings.handle(request, context)
    // An unmatched /api/* path is a genuine 404; every other path serves the SPA
    // shell so the client-side router (lustre/modem) can resolve it — the
    // history-API fallback that makes deep links like /people/5 work on a cold
    // load or reload (PRD-frontend FR-U4). Static assets are handled by the
    // serve_static middleware above and never reach here.
    ["api", ..] -> wisp.not_found()
    _ -> serve_index()
  }
}

// --- static assets ----------------------------------------------------------

/// `wisp.serve_static`, but tagging served `/static/*` files with
/// `Cache-Control: no-cache` so the browser always revalidates (the ETag still
/// yields a 304 when unchanged). lustre/dev emits a fixed `app.js`/`main.css`
/// filename with no content hash, so without this the browser serves a stale
/// bundle after a rebuild until a hard refresh.
fn serve_static_no_cache(
  request: wisp.Request,
  next handler: fn() -> wisp.Response,
) -> wisp.Response {
  let response =
    wisp.serve_static(
      request,
      under: "/static",
      from: static_directory(),
      next: handler,
    )
  case wisp.path_segments(request), response.status {
    ["static", ..], 200 | ["static", ..], 304 ->
      wisp.set_header(response, "cache-control", "no-cache")
    _, _ -> response
  }
}

/// Serve the SPA shell `priv/static/index.html` at the application root (a 404 if
/// the file is absent). Tagged `no-cache` so a reloaded deep link always
/// re-fetches the shell and picks up the latest bundle reference.
fn serve_index() -> wisp.Response {
  let index = static_directory() <> "/index.html"
  case simplifile.is_file(index) {
    Ok(True) ->
      wisp.ok()
      |> wisp.set_body(wisp.File(path: index, offset: 0, limit: option.None))
      |> wisp.set_header("content-type", "text/html; charset=utf-8")
      |> wisp.set_header("cache-control", "no-cache")
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
