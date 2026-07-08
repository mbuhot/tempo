-- meeting_required_attendees.sql — the required attendees on $1's roster, for the
-- RequireFree reschedule guard to lock and re-check (only required attendees gate
-- a booking; optional attendees never block it). $1 = meeting_id.
SELECT engineer_id FROM meeting_attendee WHERE meeting_id = $1 AND attendance = 'required' ORDER BY engineer_id;
