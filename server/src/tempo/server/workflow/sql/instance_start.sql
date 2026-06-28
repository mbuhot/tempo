-- instance_start.sql — open a new workflow draft instance (#28).
-- Inserts the anchor in the 'draft' status at its first step, owned by the
-- starting user, and returns the generated id the client routes to.
-- $1 = kind, $2 = owner account id, $3 = first step id.
INSERT INTO workflow_instance (kind, owner_id, current_step)
VALUES ($1, $2, $3)
RETURNING id;
