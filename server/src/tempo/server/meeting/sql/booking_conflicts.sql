-- booking_conflicts.sql — inside the booking transaction, AFTER engineer_lock.sql
-- has taken its row lock: recompute each required attendee's availability against
-- now-committed state and report which ones no longer hold the window free. Same
-- algorithm as find_a_time.sql (free = work_schedule hours in the engineer's own
-- as-of TZID, minus busy = live bookings ∪ focus blocks ∪ leave days ∪ holidays)
-- but for ONE fixed window instead of a search span: $2/$3/$4/$5 pin the window
-- the same way meeting_booking_open.sql does, and the candidate-day span is the
-- window's own UTC dates ±2 (wide enough to cover any attendee's TZID offset).
-- Returns one row per required engineer whose available multirange does NOT
-- contain (`@>`) the window — the conflicted attendees the caller must fail the
-- operation for. An engineer with no location on the window's date has no free
-- hours at all, so it always comes back conflicted. Empty result = safe to book.
-- $1 required engineer ids (comma-separated text), $2 date, $3 starts_at (HH:MM),
-- $4 duration minutes, $5 timezone, $6 excluded meeting id (0 = none, e.g. the
-- meeting being rescheduled — vacates its own current booking).
WITH params AS (
  SELECT tstzrange(
           (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
           (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
           '[)') AS occupies
),
attendee AS (
  SELECT trim(x)::bigint AS engineer_id
    FROM unnest(string_to_array($1, ',')) AS x
),
days AS (
  SELECT d::date AS day
    FROM generate_series(
           (lower((SELECT occupies FROM params)) AT TIME ZONE 'UTC')::date - 2,
           (upper((SELECT occupies FROM params)) AT TIME ZONE 'UTC')::date + 2,
           interval '1 day'
         ) AS d
),
located AS (
  SELECT a.engineer_id, d.day, loc.timezone AS tzid, loc.country, loc.region
    FROM attendee a
   CROSS JOIN days d
    JOIN engineer_location loc
      ON loc.engineer_id = a.engineer_id AND loc.located_during @> d.day
),
free_days AS (
  SELECT l.engineer_id,
         tstzrange(
           (l.day::text || ' ' || ws.starts::text)::timestamp AT TIME ZONE l.tzid,
           (l.day::text || ' ' || ws.ends::text)::timestamp AT TIME ZONE l.tzid,
           '[)') AS win
    FROM located l
    JOIN work_schedule ws
      ON ws.engineer_id = l.engineer_id
     AND ws.valid_at @> l.day
     AND ws.weekday = extract(isodow FROM l.day)::int - 1
),
free AS (
  SELECT a.engineer_id,
         coalesce(range_agg(f.win), '{}'::tstzmultirange) AS free
    FROM attendee a
    LEFT JOIN free_days f ON f.engineer_id = a.engineer_id
   GROUP BY a.engineer_id
),
busy_source AS MATERIALIZED (
  SELECT ma.engineer_id, b.occupies AS r
    FROM meeting_attendee ma
    JOIN attendee a ON a.engineer_id = ma.engineer_id
    JOIN meeting_booking b
      ON b.meeting_id = ma.meeting_id AND upper_inf(b.booked_during)
   WHERE b.occupies && (SELECT occupies FROM params)
     AND b.meeting_id IS DISTINCT FROM nullif($6, 0)
  UNION ALL
  SELECT f.engineer_id, f.busy_at
    FROM focus_block f
    JOIN attendee a ON a.engineer_id = f.engineer_id
   WHERE f.busy_at && (SELECT occupies FROM params)
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN leave lv ON lv.engineer_id = l.engineer_id AND lv.on_leave_during @> l.day
  UNION ALL
  SELECT l.engineer_id,
         tstzrange((l.day::text || ' 00:00')::timestamp AT TIME ZONE l.tzid,
                   ((l.day + 1)::text || ' 00:00')::timestamp AT TIME ZONE l.tzid, '[)')
    FROM located l
    JOIN holiday h
      ON h.country = l.country AND h.region IN ('', l.region) AND h.holiday_on = l.day
),
busy AS (
  SELECT engineer_id, range_agg(r) AS busy FROM busy_source GROUP BY engineer_id
),
avail AS (
  SELECT f.engineer_id, f.free - coalesce(b.busy, '{}'::tstzmultirange) AS available
    FROM free f
    LEFT JOIN busy b USING (engineer_id)
)
SELECT a.engineer_id
  FROM avail a, params p
 WHERE NOT (a.available @> p.occupies)
 ORDER BY a.engineer_id;
