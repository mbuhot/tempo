-- instance_list_for.sql — the open drafts a user can resume (#28): those they own
-- or that currently await them, newest first. Committed/cancelled are excluded.
-- $1 = account id.
SELECT id, kind, status, current_step, owner_id, assignee_id
  FROM workflow_instance
 WHERE status IN ('draft', 'awaiting_finance')
   AND (owner_id = $1 OR assignee_id = $1)
 ORDER BY updated_at DESC;
