-- engineer_role_open.sql — assert an ongoing engineer role (open-ended), contained
-- by employment via the engineer_role_within_employment PERIOD FK. Last param is
-- the audit_id. $1 = engineer_id, $2 = level, $3 = start date.
INSERT INTO engineer_role (engineer_id, level, held_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
