-- schedule_capability_gaps.sql — capability requirement lines per project per week:
-- covered = sum of allocated fractions of engineers whose weighted-average rollup
-- (unassessed skills count 0) meets the target level that week and who are off
-- leave; best = the highest qualifying-or-not rollup on the team that week, for
-- the inspector's coverage chart. $1 = as_of.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $1::date),
    date_trunc('week', $1::date) + interval '11 weeks',
    interval '1 week') AS week_start
),
demand AS (
  SELECT project_capability.project_id, project_capability.capability_id,
         project_capability.target_level, project_capability.quantity, weeks.week
  FROM weeks
  JOIN project_capability ON project_capability.required_during @> weeks.week
),
staff AS (
  SELECT demand.project_id, demand.capability_id, demand.target_level, demand.week,
         allocation.engineer_id, allocation.fraction,
         (leave.engineer_id IS NOT NULL) AS on_leave
  FROM demand
  JOIN allocation
    ON allocation.project_id = demand.project_id
   AND allocation.allocated_during @> demand.week
  LEFT JOIN leave
    ON leave.engineer_id = allocation.engineer_id
   AND leave.on_leave_during @> demand.week
),
proficiency AS (
  SELECT staff.project_id, staff.capability_id, staff.target_level, staff.week,
         staff.engineer_id, staff.fraction, staff.on_leave,
         (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
           / sum(capability_skill.weight)::numeric) AS rollup
  FROM staff
  JOIN capability_skill
    ON capability_skill.capability_id = staff.capability_id
   AND capability_skill.mapped_during @> staff.week
  LEFT JOIN engineer_skill
    ON engineer_skill.skill_id = capability_skill.skill_id
   AND engineer_skill.engineer_id = staff.engineer_id
   AND engineer_skill.assessed_during @> staff.week
  GROUP BY staff.project_id, staff.capability_id, staff.target_level, staff.week,
           staff.engineer_id, staff.fraction, staff.on_leave
)
SELECT
  demand.project_id,
  demand.capability_id,
  coalesce(capability_profile.name, '') AS name,
  demand.target_level,
  demand.week,
  demand.quantity AS quantity,
  coalesce(
    sum(proficiency.fraction)
      FILTER (WHERE proficiency.rollup >= demand.target_level
                AND NOT proficiency.on_leave),
    0) AS covered,
  coalesce(max(proficiency.rollup), 0) AS best
FROM demand
JOIN capability_profile
  ON capability_profile.capability_id = demand.capability_id
 AND capability_profile.defined_during @> demand.week
LEFT JOIN proficiency
  ON proficiency.project_id = demand.project_id
 AND proficiency.capability_id = demand.capability_id
 AND proficiency.week = demand.week
GROUP BY demand.project_id, demand.capability_id, capability_profile.name,
         demand.target_level, demand.week, demand.quantity
ORDER BY demand.project_id, name, demand.week;
