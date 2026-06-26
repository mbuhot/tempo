-- project_team.sql — the engineers engaged on one project as of $2, for the project
-- detail team card (GET /api/projects/:id; FR-CP6). Params: $1 = project_id,
-- $2 = as-of.
--
-- The board_engaged temporal join scoped to a single project: employment(@>$2)
-- anchors the employed engineer, engineer_role(@>$2) gives the as-of level,
-- rate_card(level, @>$2) the charge rate (the two-hop role × rate_card join), and
-- allocation(@>$2) ties the engineer to THIS project on the date. All INNER joins,
-- so every column is non-null. Unlike the board, the team card carries engineer_id
-- (so a card can click through to /people/:id) and omits the project/client/period
-- columns the board needs. An engineer covered by a leave fact on $2 is suppressed
-- (NOT EXISTS) exactly as on the board — the team is who is actually working the
-- project on the date. Ordered by name for a stable card list.
SELECT
  engineer.id AS engineer_id,
  coalesce(engineer_current.name, '') AS name,
  engineer_role.level,
  allocation.fraction,
  rate_card.day_rate::text AS day_rate
FROM employment
JOIN engineer ON engineer.id = employment.engineer_id
JOIN engineer_current ON engineer_current.id = engineer.id
JOIN engineer_role ON engineer_role.engineer_id = engineer.id
                  AND engineer_role.held_during @> $2::date
JOIN rate_card ON rate_card.level = engineer_role.level
              AND rate_card.effective_during @> $2::date
JOIN allocation ON allocation.engineer_id = engineer.id
               AND allocation.project_id = $1
               AND allocation.allocated_during @> $2::date
WHERE employment.employed_during @> $2::date
  AND NOT EXISTS (
    SELECT 1 FROM leave
     WHERE leave.engineer_id = engineer.id
       AND leave.on_leave_during @> $2::date
  )
ORDER BY name;
