-- salary_revise.sql — change a level's monthly_salary from $1 onward (Change). FOR
-- PORTION OF re-rates [$1, ∞) of the covering row, setting monthly_salary + audit_id;
-- PG carves off the unchanged [start, $1) remainder keeping its original audit_id.
-- The `@>` guard leaves a scheduled future version untouched. $1 = effective,
-- $2 = new monthly salary (exact decimal text, cast to numeric), $3 = level,
-- $4 = audit_id.
--
-- PG reports `UPDATE 1` even when it produces an extra remainder row, so never
-- infer a split from the affected-row count — read the rows back instead. With no
-- covering version the UPDATE matches nothing and RETURNING yields zero rows; the
-- repository rejects that (NoSuchVersion) rather than journalling a silent no-op.
UPDATE salary
   FOR PORTION OF effective_during FROM $1::date TO NULL
   SET monthly_salary = $2::text::numeric, audit_id = $4
 WHERE level = $3
   AND effective_during @> $1::date
RETURNING 1 AS revised;
