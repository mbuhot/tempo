//// Domain: the provenance journal beside the facts. `append` writes exactly one
//// `event_log` row inside the caller's transaction (used by `command.dispatch`,
//// so facts + journal commit together); `list` reads the journal newest-first
//// for the operations console. No HTTP — this layer never imports `wisp`.
////
//// `occurred_at` is the one real-clock column (system time); everything else is
//// the applied command's identity (operation tag, human summary, JSON payload).

import gleam/json.{type Json}
import gleam/list
import gleam/result
import pog
import shared/types.{type Event, Event}
import tempo/server/context.{type Context}
import tempo/server/sql

/// Append one journal row on an already-open connection: `dispatch` calls this
/// in the same transaction as the temporal fact writes, so the fact and its
/// provenance commit or roll back together. Returns the minted id (the order
/// applied). `payload` is the command re-encoded via the shared codecs.
pub fn append(
  conn: pog.Connection,
  actor actor: String,
  operation operation: String,
  summary summary: String,
  payload payload: Json,
) -> Result(Int, pog.QueryError) {
  use returned <- result.try(sql.event_log_append(
    conn,
    actor,
    operation,
    summary,
    payload,
  ))
  case returned.rows {
    [row, ..] -> Ok(row.id)
    [] -> Ok(0)
  }
}

/// List the provenance journal newest-first for the operations console. Maps
/// each generated row to the shared `Event`; `payload` is carried as a raw JSON
/// string so the journal view shows it verbatim.
pub fn list(context: Context) -> Result(List(Event), pog.QueryError) {
  use returned <- result.map(sql.event_log_list(context.db))
  list.map(returned.rows, row_to_event)
}

fn row_to_event(row: sql.EventLogListRow) -> Event {
  Event(
    id: row.id,
    occurred_at: row.occurred_at,
    actor: row.actor,
    operation: row.operation,
    summary: row.summary,
    payload: row.payload,
  )
}
