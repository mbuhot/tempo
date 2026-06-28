-- step_values_current.sql — the current value of every field in a draft (#28): the
-- latest transaction-time row per field key, value rendered to text for the boundary.
-- $1 = instance id.
SELECT DISTINCT ON (field_key) step_id, field_key, value::text
  FROM workflow_step_value
 WHERE instance_id = $1
 ORDER BY field_key, recorded_at DESC, id DESC;
