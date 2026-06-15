-- board_leave_as_of.sql — engineers on leave as of a date (ARCHITECTURE.md §5,
-- PRD FR-4). The companion to board_as_of.sql: that query suppresses anyone with
-- a covering `leave` fact; this one selects exactly those engineers so the board
-- can render them as "On leave: <kind>".
--
-- Their underlying allocation still exists; it is deliberately not joined here —
-- leave overrides the engagement in the read model. The level (and hence the
-- charge story) is still resolved so the row stays informative.
--
-- Ranges decomposed to plain `date`s at the boundary (ADR-011): valid_from/
-- valid_to are the leave period's `lower()/upper()`.
SELECT
  e.name AS engineer,
  rl.level,
  lv.kind,
  lower(lv.valid_at) AS valid_from,
  upper(lv.valid_at) AS valid_to
FROM leave lv
JOIN engineer e            ON e.id = lv.engineer_id
LEFT JOIN engineer_role rl ON rl.engineer_id = e.id AND rl.valid_at @> $1::date
WHERE lv.valid_at @> $1::date
ORDER BY e.name;
