-- meetings_upcoming.sql — scheduled meetings ending on/after $1, earliest first. Times
-- cross the wire as ISO-8601 UTC strings; canonical_offset_minutes is meeting_tz's UTC
-- offset (minutes east) at the meeting start. $1 = as_of date.
SELECT m.id AS meeting_id,
       d.title AS title,
       d.meeting_tz AS meeting_tz,
       to_char(lower(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS starts_at,
       to_char(upper(d.meeting_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at,
       ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE d.meeting_tz))
         - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int AS canonical_offset_minutes,
       d.location AS location,
       d.client_id AS client_id,
       d.project_id AS project_id
FROM meeting_detail d
JOIN meeting m ON m.id = d.meeting_id
WHERE d.status = 'scheduled'
  AND upper(d.meeting_at) >= $1::date
ORDER BY lower(d.meeting_at), m.id;
