-- engineer_role_history.sql — one engineer's full role timeline for the detail read
-- model (GET /api/engineers/:id; the RoleVersion list). Param: $1 = engineer_id.
--
-- Every engineer_role period-row for the engineer, decomposed to plain dates at the
-- boundary (ADR-011): level, lower(held_during) AS valid_from,
-- upper(held_during) AS valid_to. Ordered oldest-first by the period start. This is
-- not as-of filtered — the detail page shows the whole promotion history (including
-- future-dated rows like Marcus's L5 from 2026-07-01). upper(held_during) is
-- non-null for every seed role row (all bounded at 2027-01-01).
SELECT
  engineer_role.level,
  lower(engineer_role.held_during) AS valid_from,
  upper(engineer_role.held_during) AS valid_to
FROM engineer_role
WHERE engineer_role.engineer_id = $1
ORDER BY lower(engineer_role.held_during);
