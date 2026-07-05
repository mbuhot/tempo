-- meeting_reschedule.sql — move a meeting in place. $1 meeting_id, $2 date, $3 starts_at,
-- $4 duration_minutes, $5 timezone, $6 audit_id. RETURNING gates a missing meeting.
UPDATE meeting_detail SET
  meeting_at = tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  meeting_tz = $5,
  audit_id   = $6
WHERE meeting_id = $1
RETURNING meeting_id;
