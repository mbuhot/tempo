//// Target: Erlang only — as-of org-board handler; runs the temporal join and maps rows to shared types.

import tempo/server/context.{type Context}
import tempo/shared/types.{type AsOf, type BoardSnapshot}
import wisp

/// Handle GET /api/board?as_of=… — compute the org board as of a date.
pub fn handle(_request: wisp.Request, _context: Context) -> wisp.Response {
  todo as "P2: parse as_of, run board query, encode BoardSnapshot"
}

/// Compute the board snapshot as of a date (server-side; queries the DB).
pub fn snapshot(_context: Context, _as_of: AsOf) -> BoardSnapshot {
  todo as "P1: run as-of board query and map to BoardSnapshot"
}
