-- meeting_subject_insert.sql — insert a meeting's subject (title, client, project).
-- $1 meeting_id, $2 title, $3 client_id (0 = null), $4 project_id (0 = null), $5 audit_id.
INSERT INTO meeting_subject (meeting_id, title, client_id, project_id, audit_id)
VALUES ($1, $2, nullif($3, 0), nullif($4, 0), $5);
