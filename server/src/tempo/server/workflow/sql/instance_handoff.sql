-- instance_handoff.sql — hand a draft to Finance (#28): set the assignee and move
-- to 'awaiting_finance' so it surfaces in the assignee's resume list.
-- $1 = instance id, $2 = assignee account id.
UPDATE workflow_instance
   SET status = 'awaiting_finance', assignee_id = $2, updated_at = now()
 WHERE id = $1;
