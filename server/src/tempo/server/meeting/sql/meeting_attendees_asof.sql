-- meeting_attendees_asof.sql — attendees of the scheduled meetings ending on/after $1,
-- each with name and their location-tz-as-of-$1 local UTC offset at the meeting start.
-- Unlocated attendees have NULL timezone/offset. $1 = as_of date.
SELECT a.meeting_id AS meeting_id,
       a.engineer_id AS engineer_id,
       ec.name AS name,
       a.attendance AS attendance,
       loc.timezone AS timezone,
       CASE WHEN loc.timezone IS NULL THEN NULL
            ELSE ((extract(epoch from (lower(d.meeting_at) AT TIME ZONE loc.timezone))
                   - extract(epoch from (lower(d.meeting_at) AT TIME ZONE 'UTC'))) / 60)::int
       END AS local_offset_minutes
FROM meeting_attendee a
JOIN meeting_detail d ON d.meeting_id = a.meeting_id AND d.status = 'scheduled'
JOIN engineer_current ec ON ec.id = a.engineer_id
LEFT JOIN engineer_location loc
       ON loc.engineer_id = a.engineer_id AND loc.located_during @> $1::date
WHERE upper(d.meeting_at) >= $1::date
ORDER BY a.meeting_id, ec.name;
