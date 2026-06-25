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

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/calendar.{type Date}
import pog
import shared/command.{type Event, Event}
import shared/pagination
import tempo/server/context.{type Context}
import tempo/server/event/sql
import tempo/server/operation
import tempo/server/web/cursor.{type IdBound, IdBound}

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

/// List the provenance journal newest-first for the Activity feed, filtered by an
/// optional half-open `[from, to)` window plus optional `operation`/`actor`
/// (`event_log_list.sql`). `occurred_at` is SYSTEM time, so this feed is independent
/// of the valid-time as-of rail. Maps each row to the shared `Event`; `payload` is
/// carried as a raw JSON string so the journal view shows it verbatim.
///
/// `event_log_list.sql` guards each filter with `$n IS NULL OR …`, so a `None` drops
/// that filter — no params returns the whole journal. Squirrel emits the generated
/// wrapper (`sql.event_log_list`) with non-`Option` parameters — it never infers
/// nullable parameters, only result columns — so it cannot send SQL NULL. The
/// optional params are therefore bound here directly via `pog.nullable`, reusing the
/// exact SQL text.
///
/// Keyset pagination (issue #12): `after` is the id upper bound (id < $5; the
/// smallest id already returned, or the ceiling sentinel for the first page) and
/// `limit` caps the page. Fetches `limit + 1` so the look-ahead row tells
/// `pagination.paginate` whether a further page exists; returns the page rows plus
/// the `next_cursor` (`None` on the last page).
pub fn list(
  context: Context,
  from: Option(Date),
  to: Option(Date),
  operation: Option(String),
  actor: Option(String),
  after: IdBound,
  limit: Int,
) -> Result(#(List(Event), Option(String)), pog.QueryError) {
  let IdBound(id: cursor_id) = after
  let decoder = {
    use id <- decode.field(0, decode.int)
    use occurred_at <- decode.field(1, decode.string)
    use actor <- decode.field(2, decode.string)
    use operation <- decode.field(3, decode.string)
    use summary <- decode.field(4, decode.string)
    use payload <- decode.field(5, decode.string)
    decode.success(sql.EventLogListRow(
      id:,
      occurred_at:,
      actor:,
      operation:,
      summary:,
      payload:,
    ))
  }
  use returned <- result.map(
    event_log_list_sql
    |> pog.query
    |> pog.parameter(pog.nullable(pog.calendar_date, from))
    |> pog.parameter(pog.nullable(pog.calendar_date, to))
    |> pog.parameter(pog.nullable(pog.text, operation))
    |> pog.parameter(pog.nullable(pog.text, actor))
    |> pog.parameter(pog.int(cursor_id))
    |> pog.parameter(pog.int(limit + 1))
    |> pog.returning(decoder)
    |> pog.execute(context.db),
  )
  let #(rows, next_cursor) =
    pagination.paginate(returned.rows, limit, fn(row: sql.EventLogListRow) {
      cursor.encode_id(row.id)
    })
  #(list.map(rows, list_row_to_event), next_cursor)
}

const event_log_list_sql = "SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log
WHERE ($1::date IS NULL OR occurred_at::date >= $1)
  AND ($2::date IS NULL OR occurred_at::date < $2)
  AND ($3::text IS NULL OR operation = $3)
  AND ($4::text IS NULL OR actor = $4)
  AND id < $5::bigint
ORDER BY id DESC
LIMIT $6::int;"

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
