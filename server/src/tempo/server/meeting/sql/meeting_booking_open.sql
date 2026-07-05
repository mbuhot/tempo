-- meeting_booking_open.sql — open a new booking: the instant range the meeting occupies,
-- live from $7 onward. $1 meeting_id, $2 date, $3 starts_at (HH:MM), $4
-- duration_minutes, $5 timezone, $6 location ('' = null), $7 the real-clock instant this
-- booking becomes live (text, from meeting_clock_now.sql), $8 audit_id.
INSERT INTO meeting_booking (meeting_id, occupies, meeting_tz, location, booked_during, audit_id)
VALUES (
  $1,
  tstzrange(
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5),
    (($2::text || ' ' || $3::text)::timestamp AT TIME ZONE $5) + ($4::text || ' minutes')::interval,
    '[)'),
  $5,
  nullif($6, ''),
  tstzrange(($7::text)::timestamptz, NULL, '[)'),
  $8);
