-- timesheet_write.sql — record hours for one (engineer, project, day), contained by
-- an allocation via timesheet_within_allocation. The day is the [d, d+1) range. Last
-- param is the audit_id. $1 = engineer_id, $2 = project_id, $3 = day, $4 = hours.
INSERT INTO timesheet (engineer_id, project_id, work_day, hours, audit_id)
VALUES ($1, $2, daterange($3::date, $3::date + 1, '[)'), $4, $5);
