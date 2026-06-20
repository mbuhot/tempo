-- engineer_emergency_open.sql — open an engineer's emergency contact. Last param is
-- the audit_id. $1 = engineer_id, $2 = relation, $3 = name, $4 = phone, $5 = email,
-- $6 = from.
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during, audit_id)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'), $7);
