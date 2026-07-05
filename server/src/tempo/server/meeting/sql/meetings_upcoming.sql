-- meetings_upcoming.sql — currently-live meetings ending on/after $1, earliest first.
-- "Live" is derived, not stored: `upper_inf(b.booked_during)` is the open booking, i.e.
-- scheduled. Times cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is
-- meeting_tz's UTC offset (minutes east) at the meeting start. $1 = as_of date.
SELECT m.id AS meeting_id,
       s.title AS title,
       b.meeting_tz AS meeting_tz,
       to_char(lower(b.occupies) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(b.occupies) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       ((extract(epoch from (lower(b.occupies) AT TIME ZONE b.meeting_tz))
         - extract(epoch from (lower(b.occupies) AT TIME ZONE 'UTC'))) / 60)::int AS canonical_offset_minutes,
       b.location AS location,
       s.client_id AS client_id,
       s.project_id AS project_id
FROM meeting_booking b
JOIN meeting m ON m.id = b.meeting_id
JOIN meeting_subject s ON s.meeting_id = b.meeting_id
WHERE upper_inf(b.booked_during)
  AND upper(b.occupies) >= $1::date
ORDER BY lower(b.occupies), m.id;
