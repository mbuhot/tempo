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
import shared/access
import simplifile
import tempo/server/board/http as board
import tempo/server/client/http as clients
import tempo/server/context.{type Context, Context}
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
import tempo/server/web/access as access_admin
import tempo/server/web/events
import tempo/server/web/guard
import tempo/server/web/login
import tempo/server/web/logout
import tempo/server/web/me
import tempo/server/web/operations
import tempo/server/web/session
import tempo/server/workflow/http as workflow_http
import wisp

/// Top-level request handler: wrap every request in the standard Wisp middleware,
/// AUTHENTICATE it (resolve the signed session cookie into `Context.principal`,
/// once, up front), then route by path. `/api/*` hits the JSON handlers; anything
/// else falls through to static file serving from `priv/static`.
///
/// This is the production entry. The cookie→principal resolution lives here (not in
/// `route_request`) so a test can build a `Context` with an injected `principal` and
/// drive `route_request` directly, exercising the full routing + guards without a
/// login/cookie round-trip; the cookie path itself stays covered by the login and
/// session tests, which go through this entry.
pub fn handle_request(
  request: wisp.Request,
  context: Context,
) -> wisp.Response {
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use <- serve_static_no_cache(request)
  route_request(request, authenticate(request, context))
}

/// Resolve the request `Principal` from the signed session cookie and stash it in a
/// request-scoped clone of the (app-scoped) context. Runs only for non-static paths
/// (static is served before this), and an absent cookie costs no query.
fn authenticate(request: wisp.Request, context: Context) -> Context {
  Context(..context, principal: session.principal(request, context))
}

/// Route a request whose `Context.principal` is already resolved. The guards read
/// `context.principal`; they neither touch the cookie nor the database. Public so a
/// test can inject a principal and drive routing + guards directly.
pub fn route_request(request: wisp.Request, context: Context) -> wisp.Response {
  case wisp.path_segments(request) {
    ["api", "login"] -> login.handle(request, context)
    ["api", "logout"] -> logout.handle(request, context)
    // POST /api/operations authenticates (the guard) then authorizes per command in
    // the domain dispatch.
    ["api", "operations"] -> operations.handle(request, context)
    // Workflow drafts: un-journaled autosave reads/writes (the handlers self-guard
    // on an authenticated principal). The commit is a journaled command via
    // /api/operations, NOT here. The literal `schema` arm precedes the generic
    // `:id/:action` so it is matched first.
    ["api", "workflows"] -> workflow_http.handle_collection(request, context)
    ["api", "workflows", "schema", kind] ->
      workflow_http.handle_schema(request, context, kind)
    ["api", "workflows", id] ->
      workflow_http.handle_instance(request, context, id)
    ["api", "workflows", id, action] ->
      workflow_http.handle_action(request, context, id, action)
    // GET /api/me — the authenticated identity + effective permissions (boot-restore).
    ["api", "me"] -> {
      use principal <- guard.authenticated(context)
      me.handle(request, principal)
    }
    // Reads are gated by the permission their data needs; the two ownership reads
    // (an engineer's detail and timesheet) additionally allow the engineer their own.
    ["api", "access"] -> {
      use _principal <- guard.require(context, access.roles_manage)
      access_admin.handle(request, context)
    }
    ["api", "board"] -> {
      use _principal <- guard.require(context, access.read_projects)
      board.handle(request, context)
    }
    ["api", "timesheet"] -> {
      use principal <- guard.authenticated(context)
      timesheet.handle_read(request, context, principal)
    }
    ["api", "events"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      events.handle(request, context)
    }
    ["api", "events", "table"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      events.handle_table(request, context)
    }
    ["api", "invoices"] -> {
      use _principal <- guard.require(context, access.read_finances)
      invoices.handle_list(request, context)
    }
    ["api", "invoices", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      invoices.handle_table(request, context)
    }
    ["api", "invoices", id] -> {
      use _principal <- guard.require(context, access.read_finances)
      invoices.handle_detail(request, context, id)
    }
    ["api", "payroll"] -> {
      use _principal <- guard.require(context, access.read_finances)
      payroll.handle(request, context)
    }
    ["api", "payroll", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      payroll.handle_table(request, context)
    }
    ["api", "pnl"] -> {
      use _principal <- guard.require(context, access.read_finances)
      pnl.handle(request, context)
    }
    ["api", "pnl", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      pnl.handle_table(request, context)
    }
    ["api", "forecast"] -> {
      use _principal <- guard.require(context, access.read_finances)
      forecast.handle(request, context)
    }
    ["api", "forecast", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      forecast.handle_table(request, context)
    }
    // The bench/roster lane is part of the operational Board view, so it shares
    // read.projects (not the HR-level read.engineers the People page needs).
    ["api", "roster"] -> {
      use _principal <- guard.require(context, access.read_projects)
      roster.handle(request, context)
    }
    ["api", "people"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      people.handle(request, context)
    }
    ["api", "people", "table"] -> {
      use _principal <- guard.require(context, access.read_engineers)
      people.handle_table(request, context)
    }
    ["api", "engineers", id] -> {
      use principal <- guard.authenticated(context)
      engineers.handle_detail(request, context, id, principal)
    }
    ["api", "clients"] -> {
      use _principal <- guard.require(context, access.read_projects)
      clients.handle_list(request, context)
    }
    ["api", "clients", "table"] -> {
      use _principal <- guard.require(context, access.read_projects)
      clients.handle_table(request, context)
    }
    ["api", "clients", id] -> {
      use _principal <- guard.require(context, access.read_projects)
      clients.handle_detail(request, context, id)
    }
    ["api", "projects"] -> {
      use _principal <- guard.require(context, access.read_projects)
      projects.handle_list(request, context)
    }
    ["api", "projects", "table"] -> {
      use _principal <- guard.require(context, access.read_projects)
      projects.handle_table(request, context)
    }
    ["api", "projects", "rate-card"] -> {
      use _principal <- guard.require(context, access.read_projects)
      projects.handle_rate_card(request, context)
    }
    ["api", "projects", id] -> {
      use _principal <- guard.require(context, access.read_projects)
      projects.handle_detail(request, context, id)
    }
    ["api", "settings"] -> {
      use _principal <- guard.require(context, access.read_finances)
      settings.handle(request, context)
    }
    ["api", "settings", "rate-card", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      settings.handle_rate_card_table(request, context)
    }
    ["api", "settings", "leave-policy", "table"] -> {
      use _principal <- guard.require(context, access.read_finances)
      settings.handle_leave_policy_table(request, context)
    }
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
