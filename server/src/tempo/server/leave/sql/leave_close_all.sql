-- leave_close_all.sql — cap all of an engineer's leave from a date (§5a, pattern 4).
--
-- DELETE … FOR PORTION OF over `[end, ∞)` with no `@>` filter: intentionally
-- broad so it caps every spanning leave row to `[lo, end)` and drops the
-- fully-future ones. Invoked by `terminate_employment` as the children-first
-- cascade reaches `leave` (before `engineer_role` / `employment`).
-- $1 = engineer_id, $2 = end.
DELETE FROM leave
   FOR PORTION OF on_leave_during FROM $2::date TO NULL
 WHERE engineer_id = $1;
