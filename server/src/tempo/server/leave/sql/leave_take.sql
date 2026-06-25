-- leave_take.sql — assert an engineer on leave over a bounded period, contained by
-- employment (leave_within_employment PERIOD FK). Last param is the audit_id.
-- $1 = engineer_id, $2 = kind, $3 = from, $4 = to.
INSERT INTO leave (engineer_id, kind, on_leave_during, audit_id)
VALUES ($1, $2, daterange($3::date, $4::date, '[)'), $5);
