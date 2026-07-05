-- work_schedule_clear.sql — clear one weekday's hours from a date. $1 engineer_id,
-- $2 weekday, $3 effective.
DELETE FROM work_schedule
   FOR PORTION OF valid_at FROM $3::date TO NULL
 WHERE engineer_id = $1 AND weekday = $2;
