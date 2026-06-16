-- board_leave_as_of.sql — engineers on leave as of a date.
-- The companion to board_as_of.sql: that query suppresses anyone with a covering
-- `leave` fact; this one selects exactly those engineers so the board can render
-- them as "On leave: <kind>".
--
-- Their underlying allocation still exists; it is deliberately not joined here —
-- leave overrides the engagement in the read model. The level (and hence the
-- charge story) is still resolved so the row stays informative.
--
-- Ranges decomposed to plain `date`s at the boundary: valid_from/valid_to are
-- the leave period's `lower()/upper()`.
SELECT
  engineer.name AS engineer,
  engineer_role.level,
  leave.kind,
  lower(leave.valid_at) AS valid_from,
  upper(leave.valid_at) AS valid_to
FROM leave
JOIN engineer            ON engineer.id = leave.engineer_id
LEFT JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.valid_at @> $1::date
WHERE leave.valid_at @> $1::date
ORDER BY engineer.name;
