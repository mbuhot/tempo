-- step_value_insert.sql — append one transaction-time field value (#28). Each save
-- inserts a new row stamped at clock_timestamp(); the latest row per field is the
-- current value, and the history backs undo/redo.
-- $1 = instance id, $2 = step id, $3 = field key, $4 = value (json text).
INSERT INTO workflow_step_value (instance_id, step_id, field_key, value)
VALUES ($1, $2, $3, $4::jsonb);
