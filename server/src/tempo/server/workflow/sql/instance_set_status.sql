-- instance_set_status.sql — move a draft to a new lifecycle status (#28), e.g.
-- 'committed' or 'cancelled'.
-- $1 = instance id, $2 = status.
UPDATE workflow_instance
   SET status = $2, updated_at = now()
 WHERE id = $1;
