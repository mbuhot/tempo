-- leave_history.sql — one engineer's full leave timeline for the detail read model
-- (GET /api/engineers/:id; the LeaveRecord list). Param: $1 = engineer_id.
--
-- Every leave period-row for the engineer, decomposed to plain dates: kind,
-- lower(on_leave_during) AS valid_from, upper(on_leave_during) AS valid_to. A leave
-- window always has an end, so upper(on_leave_during) is non-null for every seed
-- row. Not as-of filtered — the detail page lists all leave. Ordered oldest-first.
SELECT
  leave.kind,
  lower(leave.on_leave_during) AS valid_from,
  upper(leave.on_leave_during) AS valid_to
FROM leave
WHERE leave.engineer_id = $1
ORDER BY lower(leave.on_leave_during);
