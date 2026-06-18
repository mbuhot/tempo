-- event_log_list.sql — the provenance journal up to an as-of date, newest first
-- (§5a; GET /api/events; the operations console feed).
--
-- Param: $1 = the as-of date (the slider). `occurred_at` is SYSTEM time — when the
-- operation was recorded. The demo seed stamps each operation with the date it
-- would naturally have been entered (timesheets at the end of their week, invoices
-- and payroll at month end; see tempo/seed_financials), so the journal reads as a
-- realistic timeline and scrubbing the slider shows only what had been recorded by
-- that date — anything recorded after $1 is hidden, rewinding the feed with the
-- rest of the UI.
--
-- `occurred_at` and `payload` are rendered to `text` at the boundary (timestamptz /
-- jsonb don't need a Squirrel type mapping); the client parses `payload` back
-- through the shared codecs. `id` doubles as the order applied, so DESC is
-- newest-first.
SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log
WHERE occurred_at::date <= $1::date
ORDER BY id DESC;
