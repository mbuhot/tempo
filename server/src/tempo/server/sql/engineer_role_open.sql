-- engineer_role_open.sql — assert an ongoing engineer role (open-ended).
--
-- Step 3 of onboarding. `held_during` runs from the start date to NULL. The
-- PERIOD FK engineer_role_within_employment is the backstop: the role can only
-- be held while the engineer is employed. The range is built in SQL so only
-- scalar params cross the boundary.
-- $1 = engineer_id, $2 = level, $3 = start date.
INSERT INTO engineer_role (engineer_id, level, held_during)
VALUES ($1, $2, daterange($3::date, NULL, '[)'));
