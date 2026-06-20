-- project_profile_open.sql — open a project's founding profile (title/summary).
-- Last param is the audit_id. $1 = project_id, $2 = title, $3 = summary, $4 = from.
INSERT INTO project_profile
  (project_id, title, summary, recorded_during, audit_id)
VALUES ($1, $2, $3, daterange($4::date, NULL, '[)'), $5);
