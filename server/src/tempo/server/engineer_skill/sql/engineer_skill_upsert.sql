-- engineer_skill_upsert.sql — record an engineer's assessed level for a skill
-- from $3 onward (delete-then-insert semantics), mirroring engineer_role_upsert.
-- The temporal DELETE clips the row covering $3 to [start, $3) and removes any
-- rows that start at or after $3, then inserts a new row bounded by employment's
-- upper end, respecting the engineer_skill_within_employment PERIOD FK. $1 =
-- engineer_id, $2 = skill_id, $3 = effective, $4 = level, $5 = audit_id.
WITH deleted AS (
  DELETE FROM engineer_skill
     FOR PORTION OF assessed_during FROM $3::date TO NULL
   WHERE engineer_id = $1 AND skill_id = $2
)
INSERT INTO engineer_skill (engineer_id, skill_id, level, assessed_during, audit_id)
SELECT $1, $2, $4, daterange($3::date, upper(employed_during), '[)'), $5
FROM employment
WHERE engineer_id = $1
  AND employed_during @> $3::date;
