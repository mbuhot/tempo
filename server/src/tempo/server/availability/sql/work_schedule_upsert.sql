-- work_schedule_upsert.sql — set one weekday's hours from a date. $1 engineer_id,
-- $2 weekday (0=Mon), $3 effective, $4 starts (HH:MM), $5 ends (HH:MM), $6 audit_id.
WITH deleted AS (
  DELETE FROM work_schedule
     FOR PORTION OF valid_at FROM $3::date TO NULL
   WHERE engineer_id = $1 AND weekday = $2
)
INSERT INTO work_schedule (engineer_id, weekday, valid_at, starts, ends, audit_id)
VALUES ($1, $2, daterange($3::date, NULL, '[)'), ($4::text)::time, ($5::text)::time, $6);
