-- employment_open.sql — assert ongoing employment (open-ended). The last param is
-- the audit_id (the event_log id of the command recording this fact).
INSERT INTO employment (engineer_id, employed_during, audit_id)
VALUES ($1, daterange($2::date, NULL, '[)'), $3);
