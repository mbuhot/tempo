//// Domain: the provenance journal beside the facts. `append` writes exactly one
//// `event_log` row inside the caller's transaction (used by `command.dispatch`,
//// so facts + journal commit together) and returns it as the shared read `Event`;
//// `list` reads the journal newest-first for the operations console, as of an
//// application date (an event is shown once that date reaches the operation's
//// effective date — see `event_log_list.sql`). No HTTP — this layer never imports
//// `wisp`.
////
//// `occurred_at` is the one real-clock column (system time); everything else is
//// the applied command's identity (operation tag, human summary, JSON payload).

import gleam/list
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/types.{type Event, Event}
import tempo/server/context.{type Context}
import tempo/server/operation
import tempo/server/sql

/// Append one journal row on an already-open connection: `dispatch` calls this in
/// the same transaction as the temporal fact writes, so the fact and its
/// provenance commit or roll back together. The handler-emitted `operation.Event`
/// (operation tag, summary, payload) is stamped with `actor`; the database mints
/// `id` and `occurred_at` and returns the whole row, mapped here to the shared
/// read `Event` so the caller gets back exactly the event it wrote — never a
/// guessed "newest row".
pub fn append(
  conn: pog.Connection,
  actor actor: String,
  event event: operation.Event,
) -> Result(Event, pog.QueryError) {
  let operation.Event(operation:, summary:, payload:) = event
  use returned <- result.try(sql.event_log_append(
    conn,
    actor,
    operation,
    summary,
    payload,
  ))
  // A single INSERT … RETURNING always yields exactly one row; an empty or multi
  // result would be a SQL/driver bug, so assert it rather than fabricate an Event.
  let assert [row] = returned.rows
  Ok(append_row_to_event(row))
}

fn append_row_to_event(row: sql.EventLogAppendRow) -> Event {
  Event(
    id: row.id,
    occurred_at: row.occurred_at,
    actor: row.actor,
    operation: row.operation,
    summary: row.summary,
    payload: row.payload,
  )
}

/// List the provenance journal newest-first for the operations console, up to
/// `as_of`: only operations recorded (`occurred_at`) on or before `as_of` are
/// returned, so the feed scrubs with the slider (the seed records each operation at
/// its natural entry date — see `set_occurred_at`). Maps each generated row to the
/// shared `Event`; `payload` is carried as a raw JSON string so the journal view
/// shows it verbatim.
pub fn list(
  context: Context,
  as_of: Date,
) -> Result(List(Event), pog.QueryError) {
  use returned <- result.map(sql.event_log_list(context.db, as_of))
  list.map(returned.rows, list_row_to_event)
}

/// Backdate one journal row's `occurred_at` to `occurred_on` (midnight that day).
/// The demo seed (`tempo/seed_financials`) uses this to record each operation at
/// the date it would naturally have been entered — timesheets at the end of their
/// week, invoices and payroll at month end — so the journal reads as a realistic
/// timeline that scrubs with the slider. Not used at runtime: production stamps
/// `occurred_at` with the wall clock as the operation is applied.
pub fn set_occurred_at(
  context: Context,
  id: Int,
  occurred_on: Date,
) -> Result(Nil, pog.QueryError) {
  use _ <- result.map(sql.event_log_set_occurred_at(context.db, id, occurred_on))
  Nil
}

fn list_row_to_event(row: sql.EventLogListRow) -> Event {
  Event(
    id: row.id,
    occurred_at: row.occurred_at,
    actor: row.actor,
    operation: row.operation,
    summary: row.summary,
    payload: row.payload,
  )
}
