-- instance_set_step.sql — advance (or move) the open step of a draft (#28).
-- $1 = instance id, $2 = next step id.
UPDATE workflow_instance
   SET current_step = $2, updated_at = now()
 WHERE id = $1;
