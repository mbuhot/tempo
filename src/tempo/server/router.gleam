//// Target: Erlang only — Wisp request router dispatching to board/timesheet handlers.

import tempo/server/context.{type Context}
import wisp

/// Top-level request handler: route by path to the board/timesheet handlers.
pub fn handle_request(
  _request: wisp.Request,
  _context: Context,
) -> wisp.Response {
  todo as "P2: route requests to board/timesheet handlers + serve static assets"
}
