-- project_requirement_set.sql — step 2 of the FOR-PORTION-OF set: insert the demand
-- line over the window [$2, $3) that project_requirement_clear.sql just vacated. The
-- PERIOD-FK `requirement_within_project` rejects (→ ContainmentViolated) a window not
-- wholly contained by the project's run; the level/quantity CHECKs reject out-of-range
-- values (→ InvalidValue). $1 = project_id, $2 = from, $3 = to, $4 = level,
-- $5 = quantity, $6 = audit_id.
INSERT INTO project_requirement
  (project_id, level, quantity, required_during, audit_id)
VALUES
  ($1, $4, $5, daterange($2::date, $3::date, '[)'), $6);
