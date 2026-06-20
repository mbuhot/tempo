-- event_log_list.sql — the provenance journal as a filterable, half-open window
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
ORDER BY id DESC;
