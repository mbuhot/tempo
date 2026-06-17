-- employment_open.sql — assert ongoing employment (open-ended).
--
-- Step 2 of onboarding. The fact is ongoing, so `employed_during` runs from the
-- start date to NULL ("the end of time"): daterange($2::date, NULL, '[)'). Only
-- scalar `date` params cross the Squirrel boundary; the range is built in SQL.
-- $1 = engineer_id, $2 = start date.
INSERT INTO employment (engineer_id, employed_during)
VALUES ($1, daterange($2::date, NULL, '[)'));
