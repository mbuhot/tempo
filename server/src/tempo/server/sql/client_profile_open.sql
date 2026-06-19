-- client_profile_open.sql — step 2 of the profile Change (and the row the seed
-- writes).
--
-- Insert the new full profile row over [$3, NULL): daterange($3::date, NULL,
-- '[)'), so only scalar params cross the Squirrel boundary. Run after
-- client_profile_close has carved [$3, NULL) out of the covering row, so the
-- WITHOUT OVERLAPS PK is satisfied. $1 = client_id, $2 = name, $3 = effective date.
INSERT INTO client_profile
  (client_id, name, recorded_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
