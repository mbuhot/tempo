//// This module contains the code to run the sql queries defined in
//// `./src/tempo/server/event/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/time/calendar.{type Date}
import pog

/// A row you get from running the `event_log_append` query
/// defined in `./src/tempo/server/event/sql/event_log_append.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EventLogAppendRow {
  EventLogAppendRow(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
///
/// `dispatch` writes exactly one of these per applied command, in the same
/// transaction as the temporal fact writes, so facts and journal commit together
/// or not at all. `occurred_at` defaults to now() (SYSTEM time). The whole row is
/// returned (id doubles as the order applied; occurred_at/payload rendered to text
/// at the boundary) so the caller maps it straight to the shared read Event —
/// never a guessed "newest row". The command is re-encoded via the shared codecs
/// as `payload`, cast to jsonb at the boundary.
/// $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_append(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: Json,
) -> Result(pog.Returned(EventLogAppendRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use occurred_at <- decode.field(1, decode.string)
    use actor <- decode.field(2, decode.string)
    use operation <- decode.field(3, decode.string)
    use summary <- decode.field(4, decode.string)
    use payload <- decode.field(5, decode.string)
    decode.success(EventLogAppendRow(
      id:,
      occurred_at:,
      actor:,
      operation:,
      summary:,
      payload:,
    ))
  }

  "-- event_log_append.sql — append one provenance row (§5a, §4, ADR-021).
--
-- `dispatch` writes exactly one of these per applied command, in the same
-- transaction as the temporal fact writes, so facts and journal commit together
-- or not at all. `occurred_at` defaults to now() (SYSTEM time). The whole row is
-- returned (id doubles as the order applied; occurred_at/payload rendered to text
-- at the boundary) so the caller maps it straight to the shared read Event —
-- never a guessed \"newest row\". The command is re-encoded via the shared codecs
-- as `payload`, cast to jsonb at the boundary.
-- $1 = actor, $2 = operation tag, $3 = summary, $4 = payload (json text).
INSERT INTO event_log (actor, operation, summary, payload)
VALUES ($1, $2, $3, $4::jsonb)
RETURNING id, occurred_at::text, actor, operation, summary, payload::text;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(json.to_string(arg_4)))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `event_log_list` query
/// defined in `./src/tempo/server/event/sql/event_log_list.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type EventLogListRow {
  EventLogListRow(
    id: Int,
    occurred_at: String,
    actor: String,
    operation: String,
    summary: String,
    payload: String,
  )
}

/// event_log_list.sql — the provenance journal as a filterable, half-open window
/// (§5a; GET /api/events?from=&to=&operation=&actor=; the Activity feed). All four
/// params are OPTIONAL — a NULL param drops its filter, so no params returns the
/// whole journal newest-first.
///
/// This is SYSTEM time (occurred_at), NOT the valid-time as-of rail. The window is
/// half-open [from, to): $1 = from (inclusive lower, occurred_at::date >= $1),
/// $2 = to (exclusive upper, occurred_at::date < $2); $3 = operation, $4 = actor are
/// exact-match filters. Each param is guarded ($n IS NULL OR …) so an absent filter
/// matches every row. The explicit ::date / ::text casts let Squirrel infer the
/// nullable param types (Option(Date)/Option(String)).
///
/// `occurred_at` and `payload` are rendered to `text` at the boundary (timestamptz /
/// jsonb don't need a Squirrel type mapping); the client parses `payload` back
/// through the shared codecs. `id` doubles as the order applied, so DESC is
/// newest-first.
///
/// Keyset pagination (#12). The id IS the total order (a bigserial, unique), so the
/// DESC keyset is `id < $5` — the cursor names the smallest id already returned, and
/// the next page is the rows below it. The first page passes a sentinel above every
/// real id so the whole journal is admitted. $6 = limit; the caller fetches limit+1
/// to detect a further page. The `event` domain module owns the executed SQL (its
/// four filter params are nullable, which Squirrel cannot express), so this file
/// exists only to keep the generated row type in sync — see event.gleam.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_list(
  db: pog.Connection,
  arg_1: Date,
  arg_2: Date,
  arg_3: String,
  arg_4: String,
  arg_5: Int,
  arg_6: Int,
) -> Result(pog.Returned(EventLogListRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use occurred_at <- decode.field(1, decode.string)
    use actor <- decode.field(2, decode.string)
    use operation <- decode.field(3, decode.string)
    use summary <- decode.field(4, decode.string)
    use payload <- decode.field(5, decode.string)
    decode.success(EventLogListRow(
      id:,
      occurred_at:,
      actor:,
      operation:,
      summary:,
      payload:,
    ))
  }

  "-- event_log_list.sql — the provenance journal as a filterable, half-open window
-- (§5a; GET /api/events?from=&to=&operation=&actor=; the Activity feed). All four
-- params are OPTIONAL — a NULL param drops its filter, so no params returns the
-- whole journal newest-first.
--
-- This is SYSTEM time (occurred_at), NOT the valid-time as-of rail. The window is
-- half-open [from, to): $1 = from (inclusive lower, occurred_at::date >= $1),
-- $2 = to (exclusive upper, occurred_at::date < $2); $3 = operation, $4 = actor are
-- exact-match filters. Each param is guarded ($n IS NULL OR …) so an absent filter
-- matches every row. The explicit ::date / ::text casts let Squirrel infer the
-- nullable param types (Option(Date)/Option(String)).
--
-- `occurred_at` and `payload` are rendered to `text` at the boundary (timestamptz /
-- jsonb don't need a Squirrel type mapping); the client parses `payload` back
-- through the shared codecs. `id` doubles as the order applied, so DESC is
-- newest-first.
--
-- Keyset pagination (#12). The id IS the total order (a bigserial, unique), so the
-- DESC keyset is `id < $5` — the cursor names the smallest id already returned, and
-- the next page is the rows below it. The first page passes a sentinel above every
-- real id so the whole journal is admitted. $6 = limit; the caller fetches limit+1
-- to detect a further page. The `event` domain module owns the executed SQL (its
-- four filter params are nullable, which Squirrel cannot express), so this file
-- exists only to keep the generated row type in sync — see event.gleam.
SELECT
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
LIMIT $6::int;
"
  |> pog.query
  |> pog.parameter(pog.calendar_date(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// event_log_set_occurred_at.sql — backdate one journal row's occurred_at to a
/// simulated entry date. Used ONLY by the demo seed (tempo/seed_financials) to give
/// the journal a realistic timeline: each operation recorded when it would naturally
/// have been entered (timesheets at the end of their week, invoices and payroll at
/// month end) rather than all at the instant the seed ran. Production records
/// occurred_at as the real wall clock (event_log_append.sql) and never calls this.
///
/// $1 = event id, $2 = the date to record it as (set to midnight of that day).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn event_log_set_occurred_at(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Date,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- event_log_set_occurred_at.sql — backdate one journal row's occurred_at to a
-- simulated entry date. Used ONLY by the demo seed (tempo/seed_financials) to give
-- the journal a realistic timeline: each operation recorded when it would naturally
-- have been entered (timesheets at the end of their week, invoices and payroll at
-- month end) rather than all at the instant the seed ran. Production records
-- occurred_at as the real wall clock (event_log_append.sql) and never calls this.
--
-- $1 = event id, $2 = the date to record it as (set to midnight of that day).
UPDATE event_log SET occurred_at = $2::date WHERE id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.calendar_date(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
