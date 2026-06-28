-- step_values_current.sql — the current step document for every step in a draft:
-- the open (unbounded-upper) version per step. The WITHOUT OVERLAPS PK guarantees
-- exactly one open span per (instance_id, step_id).
-- $1 = instance id.
SELECT step_id, value::text
  FROM workflow_step_value
 WHERE instance_id = $1 AND upper_inf(recorded_during)
 ORDER BY step_id;
