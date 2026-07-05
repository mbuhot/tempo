-- meeting_detail_insert.sql — insert a meeting's detail. $1 meeting_id, $2 date,
-- $3 starts_at (HH:MM), $4 duration_minutes, $5 timezone, $6 title, $7 location ('' = null),
-- $8 client_id (0 = null), $9 project_id (0 = null), $10 audit_id.
INSERT INTO meeting_detail
  (meeting_id, meeting_at, meeting_tz, title, location, status, client_id, project_id, audit_id)
VALUES (
  $1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $5, $6, nullif($7, ''), 'scheduled', nullif($8, 0), nullif($9, 0), $10);
