-- focus_blocks_upcoming.sql — one engineer's focus blocks ending on/after $2, with the
-- block's UTC offset in the engineer's location timezone as-of $2 (NULL when unlocated).
-- $1 engineer_id, $2 as_of.
SELECT f.id AS id,
       f.title AS title,
       to_char(lower(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(f.busy_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       ((extract(epoch from (lower(f.busy_at) AT TIME ZONE loc.timezone))
         - extract(epoch from (lower(f.busy_at) AT TIME ZONE 'UTC'))) / 60)::int AS "offset_minutes?"
FROM focus_block f
LEFT JOIN engineer_location loc
       ON loc.engineer_id = f.engineer_id AND loc.located_during @> $2::date
WHERE f.engineer_id = $1 AND upper(f.busy_at) >= $2::date
ORDER BY lower(f.busy_at), f.id;
