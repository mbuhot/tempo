//// Target: Erlang only — timesheet read (my allocations as-of a day) and write (PERIOD-FK-backed insert) handlers.

import tempo/server/context.{type Context}
import wisp

/// Handle GET /api/timesheet — my allocations as of a day, with logged hours.
pub fn handle_read(_request: wisp.Request, _context: Context) -> wisp.Response {
  todo as "P3: read engineer's allocations + hours as of a day"
}

/// Handle POST /api/timesheet — log hours for a project on a day.
pub fn handle_write(
  _request: wisp.Request,
  _context: Context,
) -> wisp.Response {
  todo as "P3: insert timesheet row (PERIOD FK backstops the write)"
}
