-- client_profile_open.sql — open a client's founding profile (the NAME). Last param
-- is the audit_id. $1 = client_id, $2 = name, $3 = from.
INSERT INTO client_profile
  (client_id, name, recorded_during, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), $4);
