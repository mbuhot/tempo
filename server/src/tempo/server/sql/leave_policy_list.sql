-- leave_policy_list.sql — the leave-accrual policy in force as of $1 (GET
-- /api/settings?as_of=$1; the leave-policy table on the Settings page; FR-ST3). One
-- row per (kind, level) whose policy span covers $1: kind + level + days_per_year,
-- ordered by kind then level. A (kind, level) with no policy row covering $1 is
-- absent from the list and is treated as unlimited (the take_leave guard does not
-- fire for it). Param: $1 = the as-of date.
SELECT
  leave_policy.kind,
  leave_policy.level,
  leave_policy.days_per_year
FROM leave_policy
WHERE leave_policy.effective_during @> $1::date
ORDER BY leave_policy.kind, leave_policy.level;
