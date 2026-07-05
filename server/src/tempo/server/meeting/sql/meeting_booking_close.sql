-- meeting_booking_close.sql — close the meeting's currently open booking (a cancel, or
-- the first half of a reschedule) at $2, the real-clock instant of this write (text,
-- from meeting_clock_now.sql). No `@>` filter: closes whatever open tail exists.
-- RETURNING empty means no booking was open (already cancelled, or the meeting doesn't
-- exist) — the repository rejects that as NoSuchVersion. RETURNING `location` carries
-- the closed booking's location forward into a reschedule's successor row, since
-- RescheduleMeeting doesn't itself carry a location.
DELETE FROM meeting_booking
   FOR PORTION OF booked_during FROM ($2::text)::timestamptz TO NULL
 WHERE meeting_id = $1
RETURNING meeting_id, location;
