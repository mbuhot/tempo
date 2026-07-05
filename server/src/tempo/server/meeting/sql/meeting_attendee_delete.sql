-- meeting_attendee_delete.sql — drop an attendee. $1 meeting_id, $2 engineer_id.
DELETE FROM meeting_attendee WHERE meeting_id = $1 AND engineer_id = $2;
