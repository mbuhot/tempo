-- board_as_of.sql — the as-of org board (ARCHITECTURE.md §5, PRD FR-1/FR-4).
--
-- One row per (engineer × allocated project) that is true as of $1::date. Leave
-- takes precedence: any engineer with a `leave` fact covering the date is
-- suppressed here (NOT EXISTS) and surfaced by board_leave_as_of.sql instead.
--
-- Charge rate is resolved from engineer_role × rate_card as of the date (the
-- two-hop temporal join, ADR-009). It is exposed as a plain `day_rate` value on
-- the row — never "where it came from" — so the same shared BoardRow holds
-- across the v1-wide -> v2-split redesign (ADR-013).
--
-- Range columns are decomposed to plain `date`s at the boundary (ADR-011): the
-- engagement window is `lower(al.valid_at)`/`upper(al.valid_at)` AS
-- valid_from/valid_to. An employed engineer with no allocation as of the date
-- yields a row with null project/client/fraction/day_rate/valid_from/valid_to.
SELECT
  e.name AS engineer,
  rl.level,
  pr.name AS project,
  cl.name AS client,
  al.fraction,
  rc.day_rate,
  lower(al.valid_at) AS valid_from,
  upper(al.valid_at) AS valid_to
FROM employment emp
JOIN engineer e            ON e.id = emp.engineer_id
LEFT JOIN engineer_role rl ON rl.engineer_id = e.id  AND rl.valid_at @> $1::date
LEFT JOIN rate_card rc     ON rc.level = rl.level     AND rc.valid_at @> $1::date
LEFT JOIN allocation al    ON al.engineer_id = e.id   AND al.valid_at @> $1::date
LEFT JOIN project pr       ON pr.id = al.project_id   AND pr.valid_at @> $1::date
LEFT JOIN contract ct      ON ct.id = pr.contract_id  AND ct.valid_at @> $1::date
LEFT JOIN client cl        ON cl.id = ct.client_id
WHERE emp.valid_at @> $1::date
  AND NOT EXISTS (
    SELECT 1 FROM leave lv
    WHERE lv.engineer_id = e.id AND lv.valid_at @> $1::date
  )
ORDER BY e.name, pr.name;
