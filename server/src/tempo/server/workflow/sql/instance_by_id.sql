-- instance_by_id.sql — the draft instance row for an id (#28). Returns 0 or 1 rows.
-- $1 = instance id.
SELECT id, kind, status, owner_id, assignee_id, current_step
  FROM workflow_instance
 WHERE id = $1;
