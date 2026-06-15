-- timesheet_write.sql — step 2 of the temporal upsert (P1-T04, ARCHITECTURE.md §5).
--
-- Insert a single-day timesheet row. The `work_day` range is built in SQL as
-- `daterange($3::date, $3::date + 1, '[)')` so the function only ever sees scalar
-- `date` params (ADR-011) — no daterange type crosses the Squirrel boundary.
--
-- The PERIOD FK to `allocation` is the backstop: a day with no covering allocation
-- is rejected (PRD FR-5). The handler runs timesheet_delete.sql then this INSERT in
-- one transaction, so a rejected insert rolls back the delete and the prior row
-- survives intact. $1 = engineer_id, $2 = project_id, $3 = the day, $4 = hours.
INSERT INTO timesheet (engineer_id, project_id, work_day, hours)
VALUES ($1, $2, daterange($3::date, $3::date + 1, '[)'), $4);
