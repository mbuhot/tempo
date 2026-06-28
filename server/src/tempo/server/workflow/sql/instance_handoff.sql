-- instance_handoff.sql — hand a draft to the Finance queue (#28): move to
-- 'awaiting_finance' and advance the open step to the finance step, so it surfaces
-- for anyone holding the commit permission. No specific assignee — Finance is a pool.
-- $1 = instance id, $2 = finance step id.
UPDATE workflow_instance
   SET status = 'awaiting_finance', current_step = $2, updated_at = now()
 WHERE id = $1;
