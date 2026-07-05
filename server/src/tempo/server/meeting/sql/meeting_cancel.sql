-- meeting_cancel.sql — mark a meeting cancelled. $1 meeting_id, $2 audit_id.
UPDATE meeting_detail SET status = 'cancelled', audit_id = $2
WHERE meeting_id = $1
RETURNING meeting_id;
