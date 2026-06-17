-- allocation_assign.sql — Assert: allocation insert over a period.
--
-- Records that an engineer is allocated to a project at `fraction` of their time,
-- over [$3, $5) (`daterange($3::date, $5::date, '[)')`). The function only ever
-- sees scalar `date` params; the range is built in SQL.
--
-- The PERIOD FKs to `employment` and `project` are the backstop: an allocation not
-- contained by both a live employment and an active project is rejected — so the
-- allocated period must stay within both the engineer's employment and the
-- project's active run. The WITHOUT OVERLAPS primary key rejects a second
-- overlapping allocation for the same engineer+project. $1 = engineer_id,
-- $2 = project_id, $3 = start day, $4 = fraction, $5 = end day.
INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during)
VALUES ($1, $2, $4, daterange($3::date, $5::date, '[)'));
