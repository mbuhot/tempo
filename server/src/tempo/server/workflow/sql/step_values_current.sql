-- step_values_current.sql — the current value of every field in a draft (#28): the
-- open (unbounded-upper) version per field, value rendered to text for the boundary.
-- The WITHOUT OVERLAPS PK guarantees exactly one open span per (step, field).
-- $1 = instance id.
SELECT step_id, field_key, value::text
  FROM workflow_step_value
 WHERE instance_id = $1 AND upper_inf(recorded_during)
 ORDER BY step_id, field_key;
