-- work_schedule_asof.sql — one engineer's weekday hours covering $2. $1 engineer_id, $2 as_of.
SELECT weekday,
       to_char(starts, 'HH24:MI') AS starts,
       to_char(ends, 'HH24:MI') AS ends
FROM work_schedule
WHERE engineer_id = $1 AND valid_at @> $2::date
ORDER BY weekday;
