-- event_log_list.sql — the provenance journal as of an application date, newest
-- first (§5a; GET /api/events; the operations console feed).
--
-- Param: $1 = the as-of application date (the slider). The journal records SYSTEM
-- time (occurred_at = when the operation was applied), but the console scrubs in
-- APPLICATION time with the rest of the UI, so an event is shown only once the
-- slider reaches the date the operation TAKES EFFECT — not when it was recorded.
-- That effective date is derived from the command payload: every command carries
-- exactly one leading date — effective / valid_from / at / billing_from /
-- period_from / day — except log_week, whose effective date is the earliest day it
-- logs. Events whose effective date is after $1 are hidden, so scrubbing the slider
-- back rewinds the journal in step with the board. (The event_log table stays pure
-- system-time provenance; the application effective date is derived here, for the
-- view, from the same payload the shared codecs wrote.)
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
WHERE coalesce(
  (payload->>'effective')::date,
  (payload->>'valid_from')::date,
  (payload->>'at')::date,
  (payload->>'billing_from')::date,
  (payload->>'period_from')::date,
  (payload->>'day')::date,
  (
    SELECT min((entry->>'day')::date)
    FROM jsonb_array_elements(payload->'entries') AS entry
  )
) <= $1::date
ORDER BY id DESC;
