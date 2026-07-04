-- project_capability_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
-- line over the window [$2, $3) that project_capability_clear.sql just vacated. The
-- PERIOD-FK `project_capability_within_run` rejects (→ ContainmentViolated) a window
-- not wholly contained by the project's run; the target_level/quantity CHECKs reject
-- out-of-range values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to,
-- $4 = capability_id, $5 = target_level, $6 = quantity, $7 = audit_id.
INSERT INTO project_capability
  (project_id, capability_id, target_level, quantity, required_during, audit_id)
VALUES
  ($1, $4, $5, $6, daterange($2::date, $3::date, '[)'), $7);
