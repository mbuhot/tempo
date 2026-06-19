-- engineer_contact_open.sql — step 2 of the contact Change (and the row Onboard
-- writes).
--
-- Insert the new full contact row over [$6, NULL): daterange($6::date, NULL,
-- '[)'), so only scalar params cross the Squirrel boundary. Run after
-- engineer_contact_close has carved [$6, NULL) out of the covering row, so the
-- WITHOUT OVERLAPS PK is satisfied. $1 = engineer_id, $2 = name, $3 = email,
-- $4 = phone, $5 = postal_address, $6 = effective date.
INSERT INTO engineer_contact
  (engineer_id, name, email, phone, postal_address, recorded_during)
VALUES ($1, $2, $3, $4, $5, daterange($6::date, NULL, '[)'));
