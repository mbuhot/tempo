-- salary_list.sql — the current monthly salary per level as of $1 (GET
-- /api/settings?as_of=$1; the salaries table on the Settings page; FR-ST2). One row
-- per level whose salary span covers $1: level + monthly_salary, ordered by level. A
-- level with no salary covering $1 is simply absent. Param: $1 = the as-of date.
SELECT
  salary.level,
  salary.monthly_salary
FROM salary
WHERE salary.effective_during @> $1::date
ORDER BY salary.level;
