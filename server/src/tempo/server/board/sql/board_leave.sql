-- board_leave.sql — engineers on leave on the date.
-- The companion to board_engaged.sql: that query suppresses anyone with a covering
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
  coalesce(engineer.name, '') AS engineer,
  engineer_role.level,
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
JOIN engineer_current engineer ON engineer.id = leave.engineer_id
LEFT JOIN engineer_role  ON engineer_role.engineer_id = engineer.id AND engineer_role.held_during @> $1::date
WHERE leave.on_leave_during @> $1::date
ORDER BY engineer.name;
