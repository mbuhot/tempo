-- project_reschedule.sql — move a project's whole plan by delta = $2 - lower(run):
-- delete the run and its allocation / requirement / capability children, then
-- re-insert all of them shifted by delta and clamped to the new [$2, $3) window
-- (a child whose clamped range is empty is dropped). One statement, so the
-- immediate PERIOD FKs check the final state at statement end; a run landing
-- outside its contract term rejects via project_within_contract. $1 = project_id,
-- $2 = new from, $3 = new to, $4 = audit_id.
WITH old_run AS (
  DELETE FROM project_run WHERE project_id = $1
  RETURNING contract_id, ($2::date - lower(active_during)) AS delta
),
old_allocation AS (
  DELETE FROM allocation WHERE project_id = $1
  RETURNING engineer_id, fraction, allocated_during
),
old_requirement AS (
  DELETE FROM project_requirement WHERE project_id = $1
  RETURNING level, quantity, required_during
),
old_capability AS (
  DELETE FROM project_capability WHERE project_id = $1
  RETURNING capability_id, target_level, quantity, required_during
),
new_run AS (
  INSERT INTO project_run (project_id, contract_id, active_during, audit_id)
  SELECT $1, contract_id, daterange($2::date, $3::date, '[)'), $4 FROM old_run
),
new_allocation AS (
  INSERT INTO allocation (engineer_id, project_id, fraction, allocated_during, audit_id)
  SELECT engineer_id, $1, fraction,
         daterange(greatest(lower(allocated_during) + delta, $2::date),
                   least(upper(allocated_during) + delta, $3::date), '[)'),
         $4
  FROM old_allocation, old_run
  WHERE greatest(lower(allocated_during) + delta, $2::date)
      < least(upper(allocated_during) + delta, $3::date)
),
new_requirement AS (
  INSERT INTO project_requirement (project_id, level, quantity, required_during, audit_id)
  SELECT $1, level, quantity,
         daterange(greatest(lower(required_during) + delta, $2::date),
                   least(upper(required_during) + delta, $3::date), '[)'),
         $4
  FROM old_requirement, old_run
  WHERE greatest(lower(required_during) + delta, $2::date)
      < least(upper(required_during) + delta, $3::date)
)
INSERT INTO project_capability (project_id, capability_id, target_level, quantity, required_during, audit_id)
SELECT $1, capability_id, target_level, quantity,
       daterange(greatest(lower(required_during) + delta, $2::date),
                 least(upper(required_during) + delta, $3::date), '[)'),
       $4
FROM old_capability, old_run
WHERE greatest(lower(required_during) + delta, $2::date)
    < least(upper(required_during) + delta, $3::date);
