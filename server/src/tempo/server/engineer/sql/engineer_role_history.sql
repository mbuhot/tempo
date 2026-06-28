-- engineer_role_history.sql — one engineer's full role timeline for the detail read
-- model (GET /api/engineers/:id; the RoleVersion list). Param: $1 = engineer_id.
--
-- Decomposed to plain dates at the boundary: level, lower(held_during) AS valid_from.
-- A current role is OPEN ([start, ∞) for a wizard-onboarded engineer), so
-- upper(held_during) is NULL — `ongoing` reports that, and `valid_to` coalesces to
-- the start so the column stays a non-null date the boundary can decode (the server
-- maps ongoing -> None). Ordered oldest-first; not as-of filtered (the whole
-- promotion history shows, including future-dated rows).
SELECT
  engineer_role.level,
  lower(engineer_role.held_during) AS valid_from,
  coalesce(upper(engineer_role.held_during), lower(engineer_role.held_during))
    AS valid_to,
  upper_inf(engineer_role.held_during) AS ongoing
FROM engineer_role
WHERE engineer_role.engineer_id = $1
ORDER BY lower(engineer_role.held_during);
