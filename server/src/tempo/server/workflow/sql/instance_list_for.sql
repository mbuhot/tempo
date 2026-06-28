-- instance_list_for.sql — the open drafts a user can resume (#28): those they own,
-- plus — when they can commit ($2) — every draft awaiting Finance (the shared queue).
-- Newest first. Committed/cancelled are excluded.
-- $1 = account id, $2 = whether the caller holds the commit permission.
SELECT id, kind, status, current_step
  FROM workflow_instance
 WHERE status IN ('draft', 'awaiting_finance')
   AND (owner_id = $1 OR ($2 AND status = 'awaiting_finance'))
 ORDER BY updated_at DESC;
