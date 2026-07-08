-- find_a_time.sql — cross-timezone slot finder: the search span (in the viewer's
-- timezone) x each candidate day's per-attendee work-schedule window, minus every
-- attendee's busy time (scheduled meetings, focus blocks, leave days, holidays),
-- intersected across every REQUIRED attendee (optional attendees ride along for
-- their offsets but never narrow the windows). Free/busy per engineer is built as a
-- `tstzmultirange` (a disjoint union of instant ranges) so subtraction and
-- intersection compose with simple multirange operators (`-`, `*`) instead of
-- hand-rolled interval arithmetic. `common` sums the required attendees' available
-- multiranges via `range_intersect_agg` and `guarded` only keeps the result when
-- every required attendee actually contributed a row (`covered = count(required)`)
-- — an attendee absent from `avail` (no location on any day, so `free` folded to
-- an empty multirange via the LEFT JOIN) must not silently drop out of the
-- requirement; instead the whole intersection is empty, i.e. zero slots. $1 from
-- date, $2 to date, $3 viewer timezone, $4 duration minutes, $5 required engineer
-- ids (comma-separated text), $6 optional engineer ids (comma-separated text, ''
-- = none), $7 excluded meeting id (0 = none, e.g. the meeting being rescheduled).
WITH params AS (
  SELECT tstzrange(
           ($1::date::text || ' 00:00')::timestamp AT TIME ZONE $3,
           (($2::date + 1)::text || ' 00:00')::timestamp AT TIME ZONE $3,
           '[)') AS search,
         make_interval(mins => $4) AS dur
),
attendee AS (
  SELECT trim(x)::bigint AS engineer_id, 'required' AS attendance
    FROM unnest(string_to_array($5, ',')) AS x
  UNION ALL
  SELECT trim(x)::bigint, 'optional'
    FROM unnest(string_to_array(nullif($6, ''), ',')) AS x
),
days AS (
  SELECT d::date AS day
    FROM generate_series($1::date - 1, $2::date + 1, interval '1 day') AS d
),
located AS (
  SELECT a.engineer_id, a.attendance, d.day, loc.timezone AS tzid, loc.country, loc.region
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
  SELECT a.engineer_id, a.attendance,
         coalesce(range_agg(f.win), '{}'::tstzmultirange) AS free
    FROM attendee a
    LEFT JOIN free_days f ON f.engineer_id = a.engineer_id
   GROUP BY a.engineer_id, a.attendance
),
busy_source AS MATERIALIZED (
  SELECT ma.engineer_id, b.occupies AS r
    FROM meeting_attendee ma
    JOIN attendee a ON a.engineer_id = ma.engineer_id
    JOIN meeting_booking b
      ON b.meeting_id = ma.meeting_id AND upper_inf(b.booked_during)
   WHERE b.occupies && (SELECT search FROM params)
     AND b.meeting_id IS DISTINCT FROM nullif($7, 0)
  UNION ALL
  SELECT f.engineer_id, f.busy_at
    FROM focus_block f
    JOIN attendee a ON a.engineer_id = f.engineer_id
   WHERE f.busy_at && (SELECT search FROM params)
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
  SELECT f.engineer_id, f.attendance,
         f.free - coalesce(b.busy, '{}'::tstzmultirange) AS available
    FROM free f
    LEFT JOIN busy b USING (engineer_id)
),
common AS (
  SELECT range_intersect_agg(available) AS windows, count(*) AS covered
    FROM avail WHERE attendance = 'required'
),
guarded AS (
  SELECT windows * tstzmultirange((SELECT search FROM params)) AS windows
    FROM common
   WHERE covered = (SELECT count(*) FROM attendee WHERE attendance = 'required')
),
slot AS (
  SELECT w.win
    FROM guarded g, unnest(g.windows) AS w(win)
   WHERE upper(w.win) - lower(w.win) >= (SELECT dur FROM params)
   ORDER BY lower(w.win)
   LIMIT 50
)
SELECT to_char(lower(s.win) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(s.win) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       a.engineer_id,
       ec.name AS name,
       a.attendance,
       loc.timezone AS "timezone?",
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(s.win) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(s.win) AT TIME ZONE 'UTC'))) / 60)::int
       END AS "offset_minutes?"
FROM slot s
CROSS JOIN attendee a
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id
      AND loc.located_during @> (lower(s.win) AT TIME ZONE 'UTC')::date
ORDER BY lower(s.win), a.attendance, ec.name;
