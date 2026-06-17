-- event_log_list.sql — read the journal newest-first (§5a; GET /api/events).
--
-- The full provenance feed for the operations console. `occurred_at` and
-- `payload` are rendered to `text` at the boundary (timestamptz / jsonb don't
-- need a Squirrel type mapping); the client parses `payload` back through the
-- shared codecs. `id` doubles as the order applied, so DESC is newest-first.
SELECT
  id,
  occurred_at::text,
  actor,
  operation,
  summary,
  payload::text
FROM event_log
ORDER BY id DESC;
