-- leave_take.sql — assert an engineer's leave (§5a, pattern 1: Assert).
--
-- Plain INSERT of a bounded leave fact. The `on_leave_during` range is built in
-- SQL as `daterange($3::date, $4::date, '[)')` so only scalar `date` params cross
-- the Squirrel boundary. The PERIOD FK to `employment` (leave_within_employment)
-- backstops it: leave outside the engineer's employment is rejected.
-- $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
INSERT INTO leave (engineer_id, kind, on_leave_during)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'));
