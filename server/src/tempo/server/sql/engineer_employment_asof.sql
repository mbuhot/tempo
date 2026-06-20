-- engineer_employment_asof.sql — one engineer's as-of employment snapshot for the
-- detail read model (GET /api/engineers/:id). Params: $1 = engineer_id, $2 = as-of.
--
-- The employment table is range-only (engineer_id, employed_during) — it carries
-- NEITHER level NOR salary. The as-of Employment row is assembled by a 3-way as-of
-- join: employment(@>$2) for the started date (lower(employed_during)), engineer_role
-- (@>$2) for the current level, and salary(level, effective_during @>$2) for the
-- monthly cost figure. All INNER joins — a row is returned only when the engineer is
-- employed AND has a role AND that level has a salary as of $2 (the seed guarantees
-- all three for every employed engineer); no row => the detail endpoint 404s.
SELECT
  employment.engineer_id,
  lower(employment.employed_during) AS started,
  engineer_role.level,
  salary.monthly_salary
FROM employment
JOIN engineer_role ON engineer_role.engineer_id = employment.engineer_id
                  AND engineer_role.held_during @> $2::date
JOIN salary ON salary.level = engineer_role.level
           AND salary.effective_during @> $2::date
WHERE employment.engineer_id = $1
  AND employment.employed_during @> $2::date;
