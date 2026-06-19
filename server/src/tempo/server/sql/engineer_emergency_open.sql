-- engineer_emergency_open.sql — step 2 of the emergency Change.
--
-- Insert the new full emergency row over [$6, NULL). Only scalar params cross the
-- boundary; the range is built in SQL. $1 = engineer_id, $2 = relation,
-- $3 = name, $4 = phone, $5 = email, $6 = effective date.
INSERT INTO engineer_emergency
  (engineer_id, relation, name, phone, email, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
