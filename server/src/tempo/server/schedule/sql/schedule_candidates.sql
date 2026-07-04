-- schedule_candidates.sql — every employed engineer qualifying for a level seat
-- (role level >= $3 as-of $1), with their worst-week free fraction over the
-- seat's window [$4, $5) (can go negative; the view floors it), a commitment
-- summary, and their best rollup among the project's required capabilities
-- (0 when the project has none). Fully committed engineers are included by
-- design — nominating one over-allocates, which the preview flags.
-- $1 = as_of, $2 = project_id, $3 = level, $4 = from, $5 = to.
WITH weeks AS (
  SELECT week_start::date AS week
  FROM generate_series(
    date_trunc('week', $4::date),
    date_trunc('week', ($5::date - 1)::timestamp),
    interval '1 week') AS week_start
),
qualifier AS (
  SELECT employment.engineer_id,
         coalesce(engineer_current.name, '') AS name,
         engineer_role.level
  FROM employment
  JOIN engineer_role
    ON engineer_role.engineer_id = employment.engineer_id
   AND engineer_role.held_during @> $1::date
   AND engineer_role.level >= $3
  JOIN engineer_current ON engineer_current.id = employment.engineer_id
  WHERE employment.employed_during @> $1::date
),
load AS (
  SELECT qualifier.engineer_id, weeks.week,
         coalesce(sum(allocation.fraction), 0) AS total
  FROM qualifier
  CROSS JOIN weeks
  LEFT JOIN allocation
    ON allocation.engineer_id = qualifier.engineer_id
   AND allocation.allocated_during @> weeks.week
  GROUP BY qualifier.engineer_id, weeks.week
),
commitment AS (
  SELECT qualifier.engineer_id,
         coalesce(
           string_agg(DISTINCT coalesce(project_current.title, ''), ', '
                      ORDER BY coalesce(project_current.title, '')),
           '') AS commitments
  FROM qualifier
  LEFT JOIN allocation
    ON allocation.engineer_id = qualifier.engineer_id
   AND allocation.allocated_during && daterange($4::date, $5::date, '[)')
  LEFT JOIN project_current ON project_current.id = allocation.project_id
  GROUP BY qualifier.engineer_id
),
required_capability AS (
  SELECT DISTINCT project_capability.capability_id
  FROM project_capability
  WHERE project_capability.project_id = $2
    AND project_capability.required_during && daterange($4::date, $5::date, '[)')
),
rollup AS (
  SELECT qualifier.engineer_id,
         max(per_capability.rollup) AS proficiency
  FROM qualifier
  JOIN required_capability ON true
  JOIN LATERAL (
    SELECT (sum(coalesce(engineer_skill.level, 0) * capability_skill.weight)::numeric
             / sum(capability_skill.weight)::numeric) AS rollup
    FROM capability_skill
    LEFT JOIN engineer_skill
      ON engineer_skill.skill_id = capability_skill.skill_id
     AND engineer_skill.engineer_id = qualifier.engineer_id
     AND engineer_skill.assessed_during @> $1::date
    WHERE capability_skill.capability_id = required_capability.capability_id
      AND capability_skill.mapped_during @> $1::date
  ) AS per_capability ON true
  GROUP BY qualifier.engineer_id
)
SELECT qualifier.engineer_id, qualifier.name, qualifier.level,
       coalesce(rollup.proficiency, 0) AS proficiency,
       (1 - max(load.total)) AS free,
       commitment.commitments
FROM qualifier
JOIN load ON load.engineer_id = qualifier.engineer_id
JOIN commitment ON commitment.engineer_id = qualifier.engineer_id
LEFT JOIN rollup ON rollup.engineer_id = qualifier.engineer_id
GROUP BY qualifier.engineer_id, qualifier.name, qualifier.level,
         rollup.proficiency, commitment.commitments
ORDER BY qualifier.level DESC, qualifier.name;
